defmodule Rail.Triage.Actions.SendTriageChatTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Scope
  alias Rail.Support
  alias Rail.Support.Schemas.Item, as: SupportItem
  alias Rail.Tools
  alias Rail.Triage
  alias Rail.Triage.Schemas.ChatMessage
  alias Rail.Triage.Schemas.Item
  alias Rail.Triage.Schemas.Thread
  alias Rail.Users

  setup do
    # A pass checks the default branch out and reads the Triage prompt from it, both through Rail.Git.
    # The project has no clone, so these answer as git would for a default branch with no .rail/prompts.
    stub(Git, :checkout_detached_worktree, fn _project, worktree_path -> {:ok, worktree_path} end)
    stub(Git, :remove_worktree, fn _clone_path, _worktree_path -> :ok end)
    stub(Git, :read_default_branch_file, fn _project, path -> {:error, "fatal: path '#{path}' does not exist"} end)

    %{project: project} = triage_project()
    %{workspace: workspace, channel: channel} = connect_slack_channel(project)
    {:ok, thread} = Triage.handle_slack_event(workspace, slack_message_event(channel, %{}))

    {:ok, %{id: user_id} = user} =
      Users.update_user(system_scope(), slack_user(workspace.external_id), %{project_ids: [project.id]})

    %{project: project, thread: thread, user_id: user_id, scope: Scope.for_user(user)}
  end

  test "records the person's line and queues a pass for it", %{
    thread: %{id: thread_id} = thread,
    scope: scope,
    user_id: user_id
  } do
    thread = triage_with(thread, triage_result([triage_bug()]))
    Phoenix.PubSub.subscribe(Rail.PubSub, "triage")

    assert {:ok, %ChatMessage{author: :person, user_id: ^user_id, thread_id: ^thread_id, text: "Shorter reply."}} =
             Triage.send_triage_chat(scope, thread, %{"text" => " Shorter reply. "})

    assert_received {:triage_scheduled, ^thread_id, 0}
    assert %Thread{status: :triaging} = Repo.get!(Thread, thread_id)
  end

  test "is the retry after a failed pass, and takes a dismissal off", %{
    thread: %{id: thread_id} = thread,
    scope: scope
  } do
    expect(Tools, :run_agent, fn _role, _argv, _opts -> {:error, :timeout} end)
    :ok = Triage.triage_thread(thread)
    {:ok, _dismissed} = Triage.dismiss_triage_thread(scope, thread)
    assert %Thread{status: :done, error: "Triage was still running" <> _after} = Repo.get!(Thread, thread_id)

    assert {:ok, %ChatMessage{}} = Triage.send_triage_chat(scope, thread, %{"text" => "Try again."})

    assert %Thread{status: :triaging, error: nil, dismissed_at: nil, dismissed_by_id: nil} =
             Repo.get!(Thread, thread_id)
  end

  test "a blank line, or one outside the person's projects, is refused", %{thread: thread, scope: scope} do
    assert {:error, %Ecto.Changeset{}} = Triage.send_triage_chat(scope, thread, %{"text" => "  "})

    assert {:error, :not_found} =
             Triage.send_triage_chat(user_scope(project_ids: ["prj_other"]), thread, %{"text" => "Hi"})

    assert [] = Repo.all(ChatMessage)
  end

  test "on a forwarded thread, the pass it asks for reads no Slack and leaves the reply alone", %{
    project: project,
    scope: scope
  } do
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
        "source" => %{"id" => "src1", "body" => "<p>Sesame.</p>", "author" => %{"type" => "user", "name" => "Marta"}}
      })
    end)

    {:ok, synced} = Support.sync_intercom_conversation(workspace, "#{unique}")
    {:ok, conversation} = Support.get_support_conversation(system_scope(), synced.id)
    item = %SupportItem{key: "sesame", kind: :bug, title: "Sesame", verdict: :confirmed, issue_title: "Lists sesame"}
    {:ok, %Thread{id: thread_id} = forwarded} = Triage.create_forwarded_thread(scope, conversation, [item])

    {:ok, _line} = Triage.send_triage_chat(scope, forwarded, %{"text" => "Make it high priority."})
    # Slack is never asked: any call to it would find no stub for Intercom's thread.
    Req.Test.stub(Rail.Slack, fn _conn -> raise "Slack was called" end)

    expect(Tools, :run_agent, fn _role, _argv, _opts ->
      dir = Thread.scratch_path(forwarded)
      assert dir |> Path.join("thread.md") |> File.read!() =~ "# Intercom conversation in Intercom"

      sesame = triage_bug(%{"key" => "sesame", "issue" => %{"title" => "Lists sesame", "priority" => "high"}})
      File.write!(Path.join(dir, "result.json"), Jason.encode!(triage_result([sesame], %{"reply" => "Ignored."})))
      {:ok, ""}
    end)

    assert :ok = Triage.triage_thread(forwarded)
    assert %Thread{status: :waiting, reply_text: nil, error: nil} = Repo.get!(Thread, thread_id)
    assert [%Item{key: "sesame", issue_priority: :high}] = Repo.all(from i in Item, where: i.thread_id == ^thread_id)
    assert {:error, :forwarded} = Triage.update_triage_reply(scope, forwarded, %{"reply_text" => "Hi Marta"})
  end
end
