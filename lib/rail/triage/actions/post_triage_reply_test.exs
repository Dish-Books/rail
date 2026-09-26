defmodule Rail.Triage.Actions.PostTriageReplyTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Scope
  alias Rail.Tools
  alias Rail.Triage
  alias Rail.Triage.Schemas.Item
  alias Rail.Triage.Schemas.Message
  alias Rail.Triage.Schemas.Thread
  alias Rail.Triage.Workers.TriageThread

  setup do
    %{project: project} = triage_project()
    %{workspace: workspace, channel: channel} = connect_slack_channel(project)
    {:ok, thread} = Triage.handle_slack_event(workspace, slack_message_event(channel, %{}))
    user = slack_user(workspace.external_id)

    %{workspace: workspace, channel: channel, thread: thread, user: user, scope: Scope.for_user(user)}
  end

  test "posts the person's edited reply as them, and the thread records it as theirs", %{
    thread: thread,
    scope: scope,
    user: %{id: user_id} = user
  } do
    %Thread{items: [item]} = triage_with(thread, %{"items" => [triage_bug(%{"issue" => nil})]})

    Req.Test.expect(Rail.Slack, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer #{user.slack_access_token}"]
      assert %{"text" => "Fixed in TRI-9, thanks for the report."} = conn |> Req.Test.raw_body() |> Jason.decode!()
      Req.Test.json(conn, %{"ok" => true, "ts" => "1790000700.000100"})
    end)

    assert {:ok, %Item{reply_posted_by_id: ^user_id, reply_edited_by_id: ^user_id, reply_posted_at: %DateTime{}}} =
             Triage.post_triage_reply(scope, item, %{"reply_text" => "Fixed in TRI-9, thanks for the report."})

    assert %Message{sent_by_user_id: ^user_id, text: "Fixed in TRI-9, thanks for the report."} =
             Repo.get_by!(Message, external_id: "1790000700.000100")

    assert %Thread{status: :done} = Repo.get!(Thread, thread.id)
    assert {:error, :already_posted} = Triage.post_triage_reply(scope, item, %{})
  end

  test "Slack's echo of that post is not triaged", %{
    workspace: workspace,
    channel: channel,
    thread: thread,
    scope: scope,
    user: %{id: user_id} = user
  } do
    %Thread{items: [item]} = triage_with(thread, %{"items" => [triage_bug(%{"issue" => nil, "reply" => "On it."})]})
    Req.Test.expect(Rail.Slack, &Req.Test.json(&1, %{"ok" => true, "ts" => "1790000800.000100"}))
    {:ok, _item} = Triage.post_triage_reply(scope, item, %{})
    Repo.delete_all(Oban.Job)

    echo =
      slack_message_event(channel, %{
        "ts" => "1790000800.000100",
        "thread_ts" => thread.external_id,
        "user" => user.slack_user_id,
        "text" => "On it."
      })

    assert {:ok, %Thread{}} = Triage.handle_slack_event(workspace, echo)
    assert [] = all_enqueued(worker: TriageThread)
    assert %Message{sent_by_user_id: ^user_id} = Repo.get_by!(Message, external_id: "1790000800.000100")

    reject(&Tools.run_agent/3)
    assert :ok = Triage.triage_thread(thread)
  end

  test "a person linked to another workspace is refused", %{thread: thread} do
    %Thread{items: [item]} = triage_with(thread, %{"items" => [triage_bug(%{"issue" => nil, "reply" => "On it."})]})

    assert {:error, :slack_other_workspace} =
             Triage.post_triage_reply(Scope.for_user(slack_user("T_ELSEWHERE")), item, %{})

    assert {:error, :slack_not_linked} = Triage.post_triage_reply(Scope.for_user(%{id: "usr_none"}), item, %{})
  end

  test "a reply waiting on its issue's link cannot go out before the issue exists", %{thread: thread, scope: scope} do
    %Thread{items: [item]} = triage_with(thread, %{"items" => [triage_bug()]})

    assert {:error, :needs_issue_link} = Triage.post_triage_reply(scope, item, %{})
  end

  test "an item being triaged again is locked", %{thread: thread, scope: scope} do
    %Thread{items: [item]} = triage_with(thread, %{"items" => [triage_bug(%{"issue" => nil})]})
    {:ok, _correction} = Triage.correct_triage_item(scope, item, %{"text" => "Wrong project."})

    assert {:error, :locked} = Triage.post_triage_reply(scope, item, %{})
  end

  test "a reply waiting on its issue's link goes out with it once the issue exists", %{thread: thread, scope: scope} do
    %Thread{items: [item]} = triage_with(thread, %{"items" => [triage_bug()]})

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_9",
              "identifier" => "TRI-9",
              "title" => "T",
              "url" => "https://linear.app/acme/issue/TRI-9",
              "state" => %{"type" => "triage"}
            }
          }
        }
      })
    end)

    stub(Rail.Pipeline, :start_task, fn _issue, :product -> {:ok, :started} end)
    Req.Test.expect(Rail.Slack, &Req.Test.json(&1, %{"ok" => false, "error" => "not_in_channel"}))
    {:ok, %Item{reply_posted_at: nil}} = Triage.create_triage_issue(scope, item, %{})

    Req.Test.expect(Rail.Slack, fn conn ->
      assert %{"text" => "Thanks Priya, we reproduced this. Filed as <https://linear.app/acme/issue/TRI-9|TRI-9>."} =
               conn |> Req.Test.raw_body() |> Jason.decode!()

      Req.Test.json(conn, %{"ok" => true, "ts" => "1790001000.000100"})
    end)

    assert {:ok, %Item{reply_posted_at: %DateTime{}}} = Triage.post_triage_reply(scope, item, %{})
  end

  test "an item that proposed no reply has nothing to post", %{thread: thread, scope: scope} do
    %Thread{items: [item]} = triage_with(thread, %{"items" => [triage_bug(%{"reply" => nil})]})

    assert {:error, :no_reply} = Triage.post_triage_reply(scope, item, %{})
  end

  test "the next pass reads the post as the teammate's, made through Rail", %{
    workspace: workspace,
    channel: channel,
    thread: thread,
    scope: scope
  } do
    %Thread{items: [item]} = triage_with(thread, %{"items" => [triage_bug(%{"issue" => nil, "reply" => "On it."})]})
    Req.Test.expect(Rail.Slack, &Req.Test.json(&1, %{"ok" => true, "ts" => "1790001100.000100"}))
    {:ok, _item} = Triage.post_triage_reply(scope, item, %{})

    {:ok, thread} =
      Triage.handle_slack_event(
        workspace,
        slack_message_event(channel, %{
          "ts" => "1790001200.000100",
          "thread_ts" => thread.external_id,
          "text" => "Thanks!"
        })
      )

    expect(Tools, :run_agent, fn _backend, _argv, _opts ->
      read = thread |> Thread.scratch_path() |> Path.join("thread.md") |> File.read!()
      assert read =~ "Michael (teammate, posted through Rail)"
      thread |> Thread.scratch_path() |> Path.join("result.json") |> File.write!(Jason.encode!(%{"items" => []}))
      {:ok, ""}
    end)

    assert :ok = Triage.triage_thread(thread)
  end
end
