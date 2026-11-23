defmodule Rail.Triage.Actions.SendTriageReplyTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Git
  alias Rail.Issues
  alias Rail.Issues.Schemas.Comment
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Workers.LinkTrackerUrl
  alias Rail.Scope
  alias Rail.Support
  alias Rail.Support.Schemas.Item, as: SupportItem
  alias Rail.Triage
  alias Rail.Triage.Schemas.Item
  alias Rail.Triage.Schemas.Message
  alias Rail.Triage.Schemas.Thread
  alias Rail.Users

  setup context do
    # A pass checks the default branch out and reads the Triage prompt from it, both through Rail.Git.
    # The project has no clone, so these answer as git would for a default branch with no .rail/prompts.
    stub(Git, :checkout_detached_worktree, fn _project, worktree_path -> {:ok, worktree_path} end)
    stub(Git, :remove_worktree, fn _clone_path, _worktree_path -> :ok end)
    stub(Git, :read_default_branch_file, fn _project, path -> {:error, "fatal: path '#{path}' does not exist"} end)

    %{project: project} = triage_project()
    %{workspace: workspace, channel: channel} = connect_slack_channel(project, external: context[:external] == true)
    {:ok, thread} = Triage.handle_slack_event(workspace, slack_message_event(channel, %{}))
    {:ok, user} = Users.update_user(system_scope(), slack_user(workspace.external_id), %{project_ids: [project.id]})
    {:ok, %Issue{identifier: tracked} = existing} = Issues.create_issue(system_scope(), project, %{title: "Ruling jumps"})

    items = [
      triage_bug(%{"key" => "ruling-jumps", "existing_issue" => tracked, "followup" => "Seen again on RAIL-41."}),
      triage_bug(%{"key" => "slot-held", "issue" => %{"title" => "A stopped run frees its slot", "priority" => "high"}}),
      triage_bug(%{"key" => "bulk-ruling", "issue" => %{"title" => "Rule several findings at once"}}),
      triage_bug(%{"key" => "fix-enabled", "issue" => %{"title" => "Fix is disabled once a round starts"}})
    ]

    thread = triage_with(thread, triage_result(items, %{"reply" => "Thanks both."}))
    scope = Scope.for_user(user)
    ignored = Enum.find(thread.items, &(&1.key == "fix-enabled"))
    {:ok, _ignored} = Triage.update_triage_item(scope, ignored, %{"ignored" => "true"})

    %{project: project, workspace: workspace, thread: thread, user: user, scope: scope, existing: existing}
  end

  test "adds the follow-up, creates the tickets not ignored, then posts the reply once with their links", %{
    thread: %{id: thread_id} = thread,
    scope: scope,
    user: %{id: user_id} = user,
    existing: %{id: existing_id}
  } do
    Req.Test.expect(Rail.Slack, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer #{user.slack_access_token}"]
      assert %{"text" => "Thanks both.\n\nFiled as " <> links} = conn |> Req.Test.raw_body() |> Jason.decode!()
      assert [_slot, _bulk] = String.split(links, ", ")
      Req.Test.json(conn, %{"ok" => true, "ts" => "1790000700.000100"})
    end)

    assert {:ok, %Thread{status: :done, reply_posted_by_id: ^user_id, send_error: nil}} =
             Triage.send_triage_reply(scope, thread)

    assert %Thread{reply_text: "Thanks both.\n\nFiled as " <> _links, reply_posted_at: %DateTime{}} =
             Repo.get!(Thread, thread_id)

    assert [%Comment{body: "Seen again on RAIL-41.\n\nFrom https://slack.example/" <> _p}] =
             Repo.all(from c in Comment, where: c.issue_id == ^existing_id)

    assert [
             %Item{key: "ruling-jumps", followup_posted_at: %DateTime{}, created_issue_id: nil, sent_at: %DateTime{}},
             %Item{key: "slot-held", created_issue_id: "iss_" <> _slot, sent_at: %DateTime{}},
             %Item{key: "bulk-ruling", created_issue_id: "iss_" <> _bulk, sent_at: %DateTime{}},
             %Item{key: "fix-enabled", ignored: true, created_issue_id: nil, sent_at: %DateTime{}}
           ] = Repo.all(from i in Item, where: i.thread_id == ^thread_id, order_by: i.position)

    assert %Message{sent_by_user_id: ^user_id} = Repo.get_by!(Message, external_id: "1790000700.000100")
    assert_enqueued(worker: LinkTrackerUrl, args: %{issue_id: existing_id})
    assert {:error, :nothing_to_send} = Triage.send_triage_reply(scope, thread)
  end

  test "Slack's echo of the reply is not triaged, and a later pass reads it as the team's own", %{
    workspace: workspace,
    thread: %{id: thread_id} = thread,
    scope: scope,
    user: %{id: user_id} = user
  } do
    Req.Test.expect(Rail.Slack, &Req.Test.json(&1, %{"ok" => true, "ts" => "1790000800.000100"}))
    {:ok, _sent} = Triage.send_triage_reply(scope, thread)
    Phoenix.PubSub.subscribe(Rail.PubSub, "triage")
    channel = Repo.preload(Repo.get!(Thread, thread_id), :slack_channel).slack_channel

    echo =
      slack_message_event(channel, %{
        "ts" => "1790000800.000100",
        "thread_ts" => thread.external_id,
        "user" => user.slack_user_id,
        "text" => "Thanks both."
      })

    assert {:ok, %Thread{id: ^thread_id}} = Triage.handle_slack_event(workspace, echo)
    refute_received {:triage_scheduled, ^thread_id, _delay}
    assert %Message{sent_by_user_id: ^user_id} = Repo.get_by!(Message, external_id: "1790000800.000100")

    {:ok, thread} =
      Triage.handle_slack_event(
        workspace,
        slack_message_event(channel, %{"ts" => "1790000900.000100", "thread_ts" => thread.external_id, "text" => "When?"})
      )

    expect(Rail.Tools, :run_agent, fn _role, _argv, _opts ->
      dir = Thread.scratch_path(thread)
      assert File.read!(Path.join(dir, "thread.md")) =~ "Michael (teammate, posted through Rail)"
      File.write!(Path.join(dir, "result.json"), Jason.encode!(triage_result([])))
      {:ok, ""}
    end)

    assert :ok = Triage.triage_thread(thread)
  end

  test "a ticket that fails stops the reply, and Send again does only what is left", %{
    thread: %{id: thread_id} = thread,
    scope: scope,
    existing: %{id: existing_id}
  } do
    expect(Issues, :create_issue, 2, fn scope, project, attrs ->
      if attrs.title == "Rule several findings at once",
        do: {:error, :db_down},
        else: call_original(Issues, :create_issue, [scope, project, attrs])
    end)

    assert {:error, {:not_created, [3]}} = Triage.send_triage_reply(scope, thread)

    assert %Thread{
             status: :waiting,
             reply_posted_at: nil,
             reply_posted_by_id: nil,
             send_started_at: nil,
             send_error:
               "Could not create item 3, so the reply was not posted. Send again to create it; nothing is done twice."
           } = Repo.get!(Thread, thread_id)

    assert [
             %Item{key: "ruling-jumps", followup_posted_at: %DateTime{}, sent_at: nil},
             %Item{key: "slot-held", created_issue_id: "iss_" <> _slot, sent_at: nil},
             %Item{key: "bulk-ruling", created_issue_id: nil, issue_created_by_id: nil},
             %Item{key: "fix-enabled"}
           ] = Repo.all(from i in Item, where: i.thread_id == ^thread_id, order_by: i.position)

    %Item{created_issue_id: slot_id} = Repo.get_by!(Item, thread_id: thread_id, key: "slot-held")
    %Issue{identifier: slot, url: slot_url} = Repo.get!(Issue, slot_id)
    slot_link = "<#{slot_url}|#{slot}>"

    expect(Issues, :create_issue, fn scope, project, %{title: "Rule several findings at once"} = attrs ->
      call_original(Issues, :create_issue, [scope, project, attrs])
    end)

    reject(&Issues.comment/3)

    Req.Test.expect(Rail.Slack, fn conn ->
      assert %{"text" => "Thanks both.\n\nFiled as " <> links} = conn |> Req.Test.raw_body() |> Jason.decode!()
      assert [^slot_link, "<" <> _bulk] = String.split(links, ", ")
      Req.Test.json(conn, %{"ok" => true, "ts" => "1790000700.000200"})
    end)

    assert {:ok, %Thread{status: :done, send_error: nil}} = Triage.send_triage_reply(scope, thread)
    assert 1 = Repo.aggregate(from(c in Comment, where: c.issue_id == ^existing_id), :count)
  end

  test "a follow-up the tracker refuses is given back, and nothing after it runs", %{
    thread: %{id: thread_id} = thread,
    scope: scope
  } do
    expect(Issues, :comment, fn _scope, _issue, _attrs -> {:error, :db_down} end)
    reject(&Issues.create_issue/3)

    assert {:error, {:not_updated, [1]}} = Triage.send_triage_reply(scope, thread)

    assert %Thread{send_error: "Could not add the follow-up on item 1, so the reply was not posted." <> _again} =
             Repo.get!(Thread, thread_id)

    assert [%Item{followup_posted_at: nil} | _rest] =
             Repo.all(from i in Item, where: i.thread_id == ^thread_id, order_by: i.position)
  end

  test "when Slack refuses the reply, the tickets stay, and Send again posts it once and makes nothing", %{
    thread: %{id: thread_id} = thread,
    scope: scope,
    user: %{id: user_id}
  } do
    Req.Test.expect(Rail.Slack, &Req.Test.json(&1, %{"ok" => false, "error" => "channel_not_found"}))

    assert {:error, {:reply_failed, _reason}} = Triage.send_triage_reply(scope, thread)

    assert %Thread{
             status: :waiting,
             reply_posted_by_id: nil,
             reply_posted_at: nil,
             send_error: "Slack did not take the reply. Send again to post it; nothing else is done twice."
           } = Repo.get!(Thread, thread_id)

    assert 2 =
             Repo.aggregate(from(i in Item, where: i.thread_id == ^thread_id and not is_nil(i.created_issue_id)), :count)

    reject(&Issues.create_issue/3)
    reject(&Issues.comment/3)
    Req.Test.expect(Rail.Slack, &Req.Test.json(&1, %{"ok" => true, "ts" => "1790000700.000300"}))

    assert {:ok, %Thread{status: :done, reply_posted_by_id: ^user_id, send_error: nil}} =
             Triage.send_triage_reply(scope, thread)
  end

  test "a follow-up or ticket another Send already claimed is not done twice", %{
    project: project,
    thread: %{id: thread_id} = thread,
    scope: scope
  } do
    {:ok, %Issue{id: other_id}} = Issues.create_issue(system_scope(), project, %{title: "Export gone"})

    Repo.insert!(%Item{
      thread_id: thread_id,
      key: "export-gone",
      position: 5,
      kind: :bug,
      title: "Export gone",
      verdict: :confirmed,
      existing_issue_id: other_id,
      followup_text: "And on BILL-9."
    })

    # A Send that outlived its lock claims the second follow-up and a ticket while this one adds the first.
    expect(Issues, :comment, fn scope, issue, attrs ->
      Repo.update_all(from(i in Item, where: i.key == "export-gone"), set: [followup_posted_at: DateTime.utc_now()])
      Repo.update_all(from(i in Item, where: i.key == "slot-held"), set: [issue_created_by_id: scope.user.id])
      call_original(Issues, :comment, [scope, issue, attrs])
    end)

    expect(Issues, :create_issue, fn scope, project, %{title: "Rule several findings at once"} = attrs ->
      call_original(Issues, :create_issue, [scope, project, attrs])
    end)

    Req.Test.expect(Rail.Slack, &Req.Test.json(&1, %{"ok" => true, "ts" => "1790000700.000400"}))

    assert {:ok, %Thread{}} = Triage.send_triage_reply(scope, thread)
    assert 0 = Repo.aggregate(from(c in Comment, where: c.issue_id == ^other_id), :count)
  end

  test "a reply another Send already claimed is not posted again", %{
    thread: %{id: thread_id} = thread,
    scope: scope
  } do
    %{id: other_id} = slack_user("T_OTHER")
    Repo.update_all(from(t in Thread, where: t.id == ^thread_id), set: [reply_posted_by_id: other_id])

    assert {:error, :already_sent} = Triage.send_triage_reply(scope, thread)
    assert %Thread{send_error: nil, reply_posted_at: nil} = Repo.get!(Thread, thread_id)
  end

  test "while a Send holds the thread, another Send, an edit and a chat line are refused", %{
    thread: %{id: thread_id, items: [item | _rest]} = thread,
    scope: scope
  } do
    Repo.update_all(from(t in Thread, where: t.id == ^thread_id), set: [send_started_at: DateTime.utc_now()])
    reject(&Issues.create_issue/3)

    assert {:error, :already_sending} = Triage.send_triage_reply(scope, thread)
    assert {:error, :already_sending} = Triage.update_triage_item(scope, item, %{"ignored" => "true"})
    assert {:error, :already_sending} = Triage.update_triage_reply(scope, thread, %{"reply_text" => "Changed"})
    assert {:error, :already_sending} = Triage.send_triage_chat(scope, thread, %{"text" => "Shorter"})
  end

  test "a lock a crash left behind frees itself after two minutes", %{
    thread: %{id: thread_id} = thread,
    scope: scope
  } do
    stale = DateTime.shift(DateTime.utc_now(), minute: -3)
    Repo.update_all(from(t in Thread, where: t.id == ^thread_id), set: [send_started_at: stale])
    Req.Test.expect(Rail.Slack, &Req.Test.json(&1, %{"ok" => true, "ts" => "1790000700.000500"}))

    assert {:ok, %Thread{status: :done, send_started_at: nil}} = Triage.send_triage_reply(scope, thread)
  end

  test "is refused while the agent works, with nothing to send, without Slack, or outside the person's projects", %{
    workspace: workspace,
    project: project,
    thread: %{id: thread_id} = thread,
    scope: scope
  } do
    reject(&Issues.create_issue/3)
    {:ok, elsewhere} = Users.update_user(system_scope(), slack_user("T_ELSEWHERE"), %{project_ids: [project.id]})
    {:ok, unlinked} = Users.update_user(system_scope(), slack_user(workspace.external_id), %{project_ids: [project.id]})
    {:ok, unlinked} = Users.update_user(system_scope(), unlinked, %{slack_access_token: nil})

    assert {:error, :slack_other_workspace} = Triage.send_triage_reply(Scope.for_user(elsewhere), thread)
    assert {:error, :slack_not_linked} = Triage.send_triage_reply(Scope.for_user(unlinked), thread)
    assert {:error, :not_found} = Triage.send_triage_reply(user_scope(project_ids: ["prj_other"]), thread)

    Repo.update_all(from(t in Thread, where: t.id == ^thread_id), set: [status: :triaging])
    assert {:error, :triaging} = Triage.send_triage_reply(scope, thread)

    Repo.update_all(from(t in Thread, where: t.id == ^thread_id), set: [status: :waiting])
    {:ok, _dismissed} = Triage.dismiss_triage_thread(scope, thread)
    assert {:error, :nothing_to_send} = Triage.send_triage_reply(scope, thread)
  end

  @tag :external
  test "in an external channel the reply goes out without the tickets' links", %{thread: thread, scope: scope} do
    Req.Test.expect(Rail.Slack, fn conn ->
      assert %{"text" => "Thanks both."} = conn |> Req.Test.raw_body() |> Jason.decode!()
      Req.Test.json(conn, %{"ok" => true, "ts" => "1790000700.000600"})
    end)

    assert {:ok, %Thread{reply_text: "Thanks both.", status: :done}} = Triage.send_triage_reply(scope, thread)
  end

  test "with no reply drafted, Send creates the tickets and posts nothing", %{
    thread: %{id: thread_id} = thread,
    scope: scope
  } do
    {:ok, _cleared} = Triage.update_triage_reply(scope, thread, %{"reply_text" => ""})

    assert {:ok, %Thread{status: :done, reply_text: "", reply_posted_at: nil}} =
             Triage.send_triage_reply(scope, thread)

    assert 2 =
             Repo.aggregate(from(i in Item, where: i.thread_id == ^thread_id and not is_nil(i.created_issue_id)), :count)
  end

  describe "a thread forwarded from Intercom" do
    setup %{project: project, scope: scope} do
      unique = System.unique_integer([:positive])
      Req.Test.expect(Rail.Intercom, &Req.Test.json(&1, %{"app" => %{"id_code" => "app#{unique}"}}))

      {:ok, workspace} =
        Support.create_intercom_workspace(system_scope(), project, %{
          "name" => "Support",
          "access_token" => "tok",
          "client_id" => "cid",
          "client_secret" => "secret"
        })

      Req.Test.expect(Rail.Intercom, fn conn ->
        Req.Test.json(conn, %{
          "id" => "#{unique}",
          "created_at" => 1_790_000_000,
          "updated_at" => 1_790_000_100,
          "state" => "open",
          "source" => %{"id" => "src1", "body" => "<p>Two bugs.</p>", "author" => %{"type" => "user", "name" => "Marta"}}
        })
      end)

      {:ok, synced} = Support.sync_intercom_conversation(workspace, "#{unique}")
      {:ok, conversation} = Support.get_support_conversation(system_scope(), synced.id)

      items = [
        %SupportItem{key: "sesame", kind: :bug, title: "Sesame", verdict: :confirmed, issue_title: "Lists sesame"},
        %SupportItem{key: "pdf", kind: :bug, title: "PDF", verdict: :not_reproduced, issue_title: "Prints the method"}
      ]

      {:ok, forwarded} = Triage.create_forwarded_thread(scope, conversation, items)
      %{forwarded: forwarded}
    end

    test "Create 2 tickets creates both, links them to the conversation and posts nothing", %{
      forwarded: %{id: forwarded_id} = forwarded,
      scope: scope
    } do
      {:ok, loaded} = Triage.get_triage_thread(scope, forwarded_id)
      assert "Create 2 tickets" = Thread.send_label(loaded)

      assert {:ok, %Thread{status: :done, reply_posted_at: nil}} = Triage.send_triage_reply(scope, forwarded)

      assert [%Item{created_issue_id: "iss_" <> _one}, %Item{created_issue_id: "iss_" <> _two}] =
               Repo.all(from i in Item, where: i.thread_id == ^forwarded_id, order_by: i.position)

      assert [_one, _two] = all_enqueued(worker: LinkTrackerUrl, args: %{title: "Intercom conversation"})
    end
  end
end
