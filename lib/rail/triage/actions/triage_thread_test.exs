defmodule Rail.Triage.Actions.TriageThreadTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Issues
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Triage
  alias Rail.Triage.Schemas.Item
  alias Rail.Triage.Schemas.Message
  alias Rail.Triage.Schemas.Thread
  alias Rail.Triage.Workers.TriageThread

  setup do
    %{project: project, role: role, remote: remote} = triage_project()
    %{workspace: workspace, channel: channel} = connect_slack_channel(project, users: %{"U_PRIYA" => "Priya"})

    {:ok, thread} =
      Triage.handle_slack_event(
        workspace,
        slack_message_event(channel, %{
          "text" => "Approved BILL-88 and it sits at Design. Could Up next show wait times?"
        })
      )

    %{project: project, role: role, remote: remote, workspace: workspace, channel: channel, thread: thread}
  end

  setup %{thread: thread} do
    bug = %{
      "key" => "stuck-at-design",
      "kind" => "bug",
      "title" => "Approved tasks stuck at Design",
      "verdict" => "confirmed",
      "summary" => "enter_stage writes the stage, then the role lookup raises.",
      "evidence" => [
        %{"file" => "lib/enter_stage.ex", "lines" => "42-45", "excerpt" => "Roles.get_role(...)", "holds" => true}
      ],
      "assumptions" => [%{"text" => "Billing is the BILL project."}],
      "existing_issue" => nil,
      "issue_note" => "No existing issue covers this.",
      "issue" => %{
        "title" => "Approve leaves tasks at Design",
        "description" => "Root cause: ...",
        "priority" => "urgent"
      },
      "reply" => "Thanks Priya, we reproduced this. Filed as {issue link}."
    }

    request = %{
      "key" => "wait-times",
      "kind" => "feature_request",
      "title" => "Wait time on every Up next row",
      "verdict" => "partly_built",
      "summary" => "Ordered by wait, but rows show none.",
      "evidence" => [%{"file" => "lib/up_next.ex", "lines" => "78", "excerpt" => "row", "holds" => false}],
      "assumptions" => [],
      "issue" => %{"title" => "Show wait times", "description" => "...", "priority" => "low"},
      "reply" => "Good call."
    }

    %{bug: bug, request: request, result_path: Path.join(Thread.scratch_path(thread), "result.json")}
  end

  test "a bug report becomes a Waiting bug item with its verdict, evidence and drafts, posting nothing", %{
    thread: %{id: thread_id} = thread,
    bug: bug,
    result_path: result_path
  } do
    expect(Tools, :run_agent, fn _backend, _argv, _opts ->
      File.write!(result_path, Jason.encode!(%{"title" => "Tasks stuck at Design", "items" => [bug]}))
      {:ok, ""}
    end)

    assert :ok = Triage.triage_thread(thread)

    assert %Thread{
             status: :waiting,
             title: "Tasks stuck at Design",
             error: nil,
             permalink: "https://slack.example/" <> _p
           } =
             Repo.get!(Thread, thread_id)

    assert [
             %Item{
               key: "stuck-at-design",
               position: 1,
               kind: :bug,
               verdict: :confirmed,
               summary: "enter_stage writes the stage, then the role lookup raises.",
               evidence: [%Item.Evidence{file: "lib/enter_stage.ex", lines: "42-45", holds: true}],
               assumptions: [%Item.Assumption{text: "Billing is the BILL project.", corrected: false}],
               issue_title: "Approve leaves tasks at Design",
               issue_priority: :urgent,
               reply_text: "Thanks Priya, we reproduced this. Filed as {issue link}.",
               created_issue_id: nil,
               reply_posted_at: nil
             }
           ] = Repo.all(from i in Item, where: i.thread_id == ^thread_id)
  end

  test "a feature request is stored as one, with how much of it is built", %{
    thread: %{id: thread_id} = thread,
    request: request,
    result_path: result_path
  } do
    expect(Tools, :run_agent, fn _backend, _argv, _opts ->
      File.write!(result_path, Jason.encode!(%{"items" => [request]}))
      {:ok, ""}
    end)

    assert :ok = Triage.triage_thread(thread)

    assert [%Item{kind: :feature_request, verdict: :partly_built, evidence: [%Item.Evidence{holds: false}]}] =
             Repo.all(from i in Item, where: i.thread_id == ^thread_id)
  end

  test "a thread that needs no response ends Done with the reason, and nothing to review", %{
    thread: %{id: thread_id, external_id: ts} = thread,
    result_path: result_path
  } do
    expect(Tools, :run_agent, fn _backend, _argv, _opts ->
      File.write!(
        result_path,
        Jason.encode!(%{
          "title" => "Scheduling",
          "messages" => [%{"ts" => ts, "needs_response" => false, "reason" => "Scheduling between teammates"}],
          "items" => []
        })
      )

      {:ok, ""}
    end)

    assert :ok = Triage.triage_thread(thread)

    assert %Thread{status: :done, no_response_reason: "Scheduling between teammates"} = Repo.get!(Thread, thread_id)

    assert [%Message{no_response_reason: "Scheduling between teammates", triaged_at: %DateTime{}}] =
             Repo.all(from m in Message, where: m.thread_id == ^thread_id)

    assert [] = Repo.all(from i in Item, where: i.thread_id == ^thread_id)
  end

  test "an item an existing issue covers links it and drafts no issue", %{
    project: project,
    thread: %{id: thread_id} = thread,
    request: request,
    result_path: result_path
  } do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_tri_23",
              "identifier" => "TRI-23",
              "title" => "Wait times",
              "state" => %{"id" => "st_todo", "name" => "Todo", "type" => "unstarted"}
            }
          }
        }
      })
    end)

    {:ok, %{id: issue_id}} = Issues.create_issue(system_scope(), project, %{title: "Wait times"})

    expect(Tools, :run_agent, fn _backend, _argv, _opts ->
      File.write!(result_path, Jason.encode!(%{"items" => [Map.put(request, "existing_issue", "TRI-23")]}))
      {:ok, ""}
    end)

    assert :ok = Triage.triage_thread(thread)

    assert [%Item{existing_issue_id: ^issue_id, issue_title: nil, issue_description: nil, reply_text: "Good call."}] =
             Repo.all(from i in Item, where: i.thread_id == ^thread_id)
  end

  test "a bug and an unrelated request become two items, each linked from its passage", %{
    thread: %{id: thread_id, external_id: ts} = thread,
    bug: bug,
    request: request,
    result_path: result_path
  } do
    expect(Tools, :run_agent, fn _backend, _argv, _opts ->
      File.write!(
        result_path,
        Jason.encode!(%{
          "messages" => [
            %{
              "ts" => ts,
              "needs_response" => true,
              "items" => [
                %{
                  "key" => "stuck-at-design",
                  "change" => "raised",
                  "passage" => "Approved BILL-88 and it sits at Design."
                },
                %{"key" => "wait-times", "change" => "raised", "passage" => "Could Up next show wait times?"}
              ]
            }
          ],
          "items" => [bug, request]
        })
      )

      {:ok, ""}
    end)

    assert :ok = Triage.triage_thread(thread)

    assert [%Item{key: "stuck-at-design", position: 1}, %Item{key: "wait-times", position: 2}] =
             Repo.all(from i in Item, where: i.thread_id == ^thread_id, order_by: i.position)

    assert [%Message{item_links: [%{item_key: "stuck-at-design", change: :raised}, %{item_key: "wait-times"}]}] =
             Repo.all(from m in Message, where: m.thread_id == ^thread_id)
  end

  test "a later message widens an item by its key, adds a new one, and leaves settled items alone", %{
    workspace: workspace,
    channel: channel,
    thread: %{id: thread_id} = thread,
    bug: bug,
    result_path: result_path
  } do
    fixed = %{
      "key" => "switcher-resets",
      "kind" => "bug",
      "title" => "Switcher resets",
      "verdict" => "already_fixed",
      "summary" => "Fixed in TRI-9."
    }

    expect(Tools, :run_agent, fn _backend, _argv, _opts ->
      File.write!(result_path, Jason.encode!(%{"items" => [bug, fixed]}))
      {:ok, ""}
    end)

    assert :ok = Triage.triage_thread(thread)

    {:ok, thread} =
      Triage.handle_slack_event(
        workspace,
        slack_message_event(channel, %{
          "ts" => "1790000100.000200",
          "thread_ts" => thread.external_id,
          "text" => "Same on BILL-91. Also the export is gone."
        })
      )

    expect(Tools, :run_agent, fn _backend, argv, _opts ->
      assert Enum.any?(argv, &(&1 =~ "`stuck-at-design`" and &1 =~ "`switcher-resets` (settled"))

      widened = Map.put(bug, "summary", "Both BILL-88 and BILL-91.")
      rewritten = Map.put(fixed, "summary", "A pass must not touch this.")

      export = %{
        "key" => "export-gone",
        "kind" => "bug",
        "title" => "CSV export gone",
        "verdict" => "not_reproduced"
      }

      File.write!(
        result_path,
        Jason.encode!(%{
          "messages" => [
            %{
              "ts" => "1790000100.000200",
              "needs_response" => true,
              "items" => [
                %{"key" => "stuck-at-design", "change" => "widened", "passage" => "Same on BILL-91."},
                %{"key" => "export-gone", "change" => "added", "passage" => "Also the export is gone."}
              ]
            }
          ],
          "items" => [widened, rewritten, export]
        })
      )

      {:ok, ""}
    end)

    assert :ok = Triage.triage_thread(thread)

    assert [
             %Item{key: "stuck-at-design", position: 1, summary: "Both BILL-88 and BILL-91."},
             %Item{key: "switcher-resets", position: 2, summary: "Fixed in TRI-9."},
             %Item{key: "export-gone", position: 3, verdict: :not_reproduced}
           ] = Repo.all(from i in Item, where: i.thread_id == ^thread_id, order_by: i.position)
  end

  test "a report from a bot in an opted-in channel becomes a bug with an issue draft and no reply", %{
    project: project,
    bug: bug
  } do
    %{workspace: workspace, channel: channel} = connect_slack_channel(project, bot_messages: true)

    {:ok, %{id: thread_id} = thread} =
      Triage.handle_slack_event(
        workspace,
        slack_message_event(channel, %{
          "subtype" => "bot_message",
          "bot_id" => "B_POSTHOG",
          "username" => "PostHog",
          "text" => "TypeError in checkout"
        })
      )

    expect(Tools, :run_agent, fn _backend, _argv, _opts ->
      assert thread |> Thread.scratch_path() |> Path.join("thread.md") |> File.read!() =~ "PostHog (bot)"

      thread
      |> Thread.scratch_path()
      |> Path.join("result.json")
      |> File.write!(Jason.encode!(%{"items" => [Map.put(bug, "reply", nil)]}))

      {:ok, ""}
    end)

    assert :ok = Triage.triage_thread(thread)

    assert [%Item{kind: :bug, issue_title: "Approve leaves tasks at Design", reply_text: nil}] =
             Repo.all(from i in Item, where: i.thread_id == ^thread_id)
  end

  test "the agent gets an MCP token whose hash the thread holds only while the pass runs", %{
    thread: %{id: thread_id} = thread,
    role: %{backend_id: backend_id},
    result_path: result_path
  } do
    expect(Tools, :run_agent, fn %{id: ^backend_id}, argv, opts ->
      assert %{"RAIL_MCP_TOKEN" => token} = opts[:env]
      assert opts[:timeout] == to_timeout(minute: 30)
      assert File.dir?(opts[:cd])
      assert Enum.any?(argv, &(&1 =~ result_path))

      hash = :crypto.hash(:sha256, token)
      assert %Thread{mcp_token_hash: ^hash, triage_started_at: %DateTime{}} = Repo.get!(Thread, thread_id)

      File.write!(result_path, Jason.encode!(%{"items" => []}))
      {:ok, ""}
    end)

    assert :ok = Triage.triage_thread(thread)
    assert %Thread{mcp_token_hash: nil, triage_started_at: nil} = Repo.get!(Thread, thread_id)
  end

  test "a pass held by another snoozes", %{thread: thread, result_path: result_path} do
    expect(Tools, :run_agent, fn _backend, _argv, _opts ->
      assert {:snooze, 30} = Triage.triage_thread(thread)
      File.write!(result_path, Jason.encode!(%{"items" => []}))
      {:ok, ""}
    end)

    assert :ok = Triage.triage_thread(thread)
  end

  test "a thread with nothing new to read never runs an agent", %{project: project} do
    %{workspace: workspace, channel: channel} = connect_slack_channel(project)

    {:ok, thread} =
      Triage.handle_slack_event(
        workspace,
        slack_message_event(channel, %{"subtype" => "bot_message", "bot_id" => "B_OTHER", "text" => "deploy done"})
      )

    reject(&Tools.run_agent/3)

    assert :ok = Triage.triage_thread(thread)
  end

  test "a message that arrives during a pass schedules another", %{
    workspace: workspace,
    channel: channel,
    thread: %{id: thread_id} = thread,
    result_path: result_path
  } do
    expect(Tools, :run_agent, fn _backend, _argv, _opts ->
      Repo.delete_all(Oban.Job)

      Triage.handle_slack_event(
        workspace,
        slack_message_event(channel, %{"ts" => "1790000300.000100", "thread_ts" => thread.external_id})
      )

      Repo.delete_all(Oban.Job)
      File.write!(result_path, Jason.encode!(%{"items" => []}))
      {:ok, ""}
    end)

    assert :ok = Triage.triage_thread(thread)
    assert_enqueued(worker: TriageThread, args: %{thread_id: thread_id})
    assert %Thread{status: :triaging} = Repo.get!(Thread, thread_id)
  end

  describe "a pass that fails keeps the items and says why" do
    test "when the project has no Triage role", %{thread: %{id: thread_id} = thread, role: role} do
      {:ok, _deleted} = Roles.delete_role(system_scope(), role)
      reject(&Tools.run_agent/3)

      assert :ok = Triage.triage_thread(thread)
      assert %Thread{status: :waiting, error: "This project has no Triage role."} = Repo.get!(Thread, thread_id)
    end

    test "when the agent fails, times out or is not dispatched", %{thread: %{id: thread_id} = thread} do
      for {outcome, error} <- [
            {{:error, {:exit, 2}}, "Triage exited with code 2."},
            {{:error, :timeout}, "Triage was still running after 30 minutes, so it was stopped."},
            {{:error, :dispatch_disabled}, "Dispatch is switched off, so triage did not run."}
          ] do
        expect(Tools, :run_agent, fn _backend, _argv, _opts -> outcome end)

        assert :ok = Triage.triage_thread(thread)
        assert %Thread{error: ^error} = Repo.get!(Thread, thread_id)
      end
    end

    test "when the code cannot be checked out", %{thread: %{id: thread_id} = thread, remote: remote} do
      File.rm_rf!(remote)
      reject(&Tools.run_agent/3)

      assert :ok = Triage.triage_thread(thread)
      assert %Thread{error: error} = Repo.get!(Thread, thread_id)
      assert error =~ "fatal"
    end

    test "when GitHub will not lend a token to fetch with", %{thread: %{id: thread_id} = thread} do
      Req.Test.stub(Rail.GitHub.Client, &Plug.Conn.send_resp(&1, 500, "down"))
      reject(&Tools.run_agent/3)

      assert :ok = Triage.triage_thread(thread)
      assert %Thread{error: "Triage failed: " <> _reason} = Repo.get!(Thread, thread_id)
    end

    test "when the result is missing or malformed", %{thread: %{id: thread_id} = thread, result_path: result_path} do
      expect(Tools, :run_agent, fn _backend, _argv, _opts ->
        File.write!(result_path, "{not json")
        {:ok, ""}
      end)

      assert :ok = Triage.triage_thread(thread)
      assert %Thread{error: "Triage finished without writing a result Rail could read."} = Repo.get!(Thread, thread_id)
    end

    test "when Slack cannot be read", %{thread: %{id: thread_id} = thread} do
      Req.Test.stub(Rail.Slack, &Req.Test.json(&1, %{"ok" => false, "error" => "ratelimited"}))
      reject(&Tools.run_agent/3)

      assert :ok = Triage.triage_thread(thread)
      assert %Thread{error: "Could not read the thread from Slack: ratelimited"} = Repo.get!(Thread, thread_id)

      Req.Test.stub(Rail.Slack, &Req.Test.transport_error(&1, :econnrefused))
      assert :ok = Triage.triage_thread(thread)

      assert %Thread{error: "Could not read the thread from Slack: %Req.TransportError{reason: :econnrefused}"} =
               Repo.get!(Thread, thread_id)
    end
  end

  test "reads the whole thread from Slack first, naming everyone in it", %{
    thread: %{id: thread_id} = thread,
    result_path: result_path
  } do
    parent = %{"ts" => thread.external_id, "user" => "U_PRIYA", "text" => "Approved BILL-88 and it sits at Design."}

    replies = [
      parent,
      %{"ts" => "1790000100.000100", "thread_ts" => thread.external_id, "user" => "U_DAN", "text" => "Same on BILL-91"},
      %{"ts" => "1790000200.000100", "thread_ts" => thread.external_id, "user" => "U_DAN", "text" => "and BILL-92"},
      %{"ts" => "1790000300.000100", "thread_ts" => thread.external_id, "user" => "U_GHOST", "text" => "me too"},
      %{"ts" => "1790000400.000100", "thread_ts" => thread.external_id, "username" => "Deploy bot", "text" => "deployed"}
    ]

    test = self()

    Req.Test.stub(Rail.Slack, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      case {conn.request_path, conn.query_params["user"]} do
        {"/api/conversations.replies", _user} ->
          Req.Test.json(conn, %{"ok" => true, "messages" => replies})

        {"/api/chat.getPermalink", _user} ->
          Req.Test.json(conn, %{"ok" => true, "permalink" => "https://slack.example/p1"})

        {"/api/users.info", "U_GHOST"} ->
          Req.Test.json(conn, %{"ok" => false, "error" => "user_not_found"})

        {"/api/users.info", user} ->
          send(test, {:looked_up, user})
          Req.Test.json(conn, %{"ok" => true, "user" => %{"real_name" => "Dan Okafor"}})
      end
    end)

    expect(Tools, :run_agent, fn _backend, _argv, _opts ->
      read = thread |> Thread.scratch_path() |> Path.join("thread.md") |> File.read!()
      assert read =~ "Dan Okafor · "
      assert read =~ "Same on BILL-91"
      assert read =~ "U_GHOST · "
      assert read =~ "Deploy bot (bot)"
      File.write!(result_path, Jason.encode!(%{"items" => []}))
      {:ok, ""}
    end)

    assert :ok = Triage.triage_thread(thread)

    assert_received {:looked_up, "U_DAN"}
    refute_received {:looked_up, "U_DAN"}
    assert 5 = Repo.aggregate(from(m in Message, where: m.thread_id == ^thread_id), :count)
  end
end
