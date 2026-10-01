defmodule Rail.Triage.Actions.TriageThreadTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Triage
  alias Rail.Triage.Schemas.Item
  alias Rail.Triage.Schemas.Message
  alias Rail.Triage.Schemas.Thread

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
              "url" => "https://linear.app/acme/issue/TRI-23",
              "state" => %{"id" => "st_todo", "name" => "Todo", "type" => "unstarted"}
            }
          }
        }
      })
    end)

    {:ok, %{id: issue_id}} = Issues.create_issue(system_scope(), project, %{title: "Wait times"})

    expect(Tools, :run_agent, fn _backend, _argv, _opts ->
      issues = thread |> Thread.scratch_path() |> Path.join("issues.md") |> File.read!()
      assert issues =~ "## TRI-23 · Triage · Wait times\n\nLink: https://linear.app/acme/issue/TRI-23"
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
    %{workspace: workspace, channel: channel} = connect_slack_channel(project, bot_triage_enabled: true)

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

  test "the agent runs the triage prompt merged to the project's .rail/prompts", %{
    project: project,
    remote: remote,
    thread: thread,
    result_path: result_path
  } do
    File.mkdir_p!(Path.join(remote, ".rail/prompts"))
    File.write!(Path.join(remote, ".rail/prompts/triage.md"), "From the repo.\n")
    git!(remote, ["add", "."])
    git!(remote, ["commit", "-m", "add prompt"])
    git!(project.clone_path, ["fetch", "origin", "main"])

    expect(Tools, :run_agent, fn _backend, argv, _opts ->
      assert ["--append-system-prompt", "From the repo."] in Enum.chunk_every(argv, 2, 1)
      File.write!(result_path, Jason.encode!(%{"items" => []}))
      {:ok, ""}
    end)

    assert :ok = Triage.triage_thread(thread)
  end

  test "the agent runs the stored triage prompt when the repo has no file for it", %{
    thread: thread,
    result_path: result_path
  } do
    expect(Tools, :run_agent, fn _backend, argv, _opts ->
      assert ["--append-system-prompt", "You triage."] in Enum.chunk_every(argv, 2, 1)
      File.write!(result_path, Jason.encode!(%{"items" => []}))
      {:ok, ""}
    end)

    assert :ok = Triage.triage_thread(thread)
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
    Phoenix.PubSub.subscribe(Rail.PubSub, "triage")

    expect(Tools, :run_agent, fn _backend, _argv, _opts ->
      Triage.handle_slack_event(
        workspace,
        slack_message_event(channel, %{"ts" => "1790000300.000100", "thread_ts" => thread.external_id})
      )

      File.write!(result_path, Jason.encode!(%{"items" => []}))
      {:ok, ""}
    end)

    assert :ok = Triage.triage_thread(thread)
    assert_received {:triage_scheduled, ^thread_id, 15_000}
    assert_received {:triage_scheduled, ^thread_id, 0}
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

  test "a later pass sets the drafts to what it drafted", %{
    workspace: workspace,
    channel: channel,
    thread: %{id: thread_id} = thread,
    bug: bug,
    result_path: result_path
  } do
    %Thread{items: [_item]} = triage_with(thread, %{"items" => [bug]})

    {:ok, thread} =
      Triage.handle_slack_event(
        workspace,
        slack_message_event(channel, %{"ts" => "1790000100.000200", "thread_ts" => thread.external_id, "text" => "+1"})
      )

    expect(Tools, :run_agent, fn _backend, _argv, _opts ->
      rewritten =
        Map.merge(bug, %{
          "reply" => "Couldn't reproduce yet.",
          "issue" => %{"title" => "Rail's new title", "description" => "New.", "priority" => "low"}
        })

      File.write!(result_path, Jason.encode!(%{"items" => [rewritten]}))
      {:ok, ""}
    end)

    assert :ok = Triage.triage_thread(thread)

    assert [
             %Item{
               reply_text: "Couldn't reproduce yet.",
               issue_title: "Rail's new title",
               issue_description: "New.",
               issue_priority: :low
             }
           ] = Repo.all(from i in Item, where: i.thread_id == ^thread_id)
  end

  describe "images attached to messages" do
    test "a screenshot posted with its text reaches the pass under that message, for the agent to open", %{
      workspace: workspace,
      channel: channel,
      thread: thread,
      result_path: result_path
    } do
      stub_slack(
        users: %{"U_PRIYA" => "Priya"},
        files: %{"/files-pri/T1-F_SHOT/button.png" => {"image/png", "png-bytes"}}
      )

      {:ok, thread} =
        Triage.handle_slack_event(
          workspace,
          slack_message_event(channel, %{
            "subtype" => "file_share",
            "ts" => "1790000100.000200",
            "thread_ts" => thread.external_id,
            "text" => "this button is broken",
            "files" => [
              %{
                "id" => "F_SHOT",
                "name" => "button.png",
                "mimetype" => "image/png",
                "url_private" => "https://files.slack.com/files-pri/T1-F_SHOT/button.png"
              }
            ]
          })
        )

      path = Path.join([Thread.scratch_path(thread), "images", "1790000100.000200-1.png"])

      expect(Tools, :run_agent, fn _backend, argv, _opts ->
        read = thread |> Thread.scratch_path() |> Path.join("thread.md") |> File.read!()

        assert read =~
                 ~r/### 1790000100\.000200 · Priya · [^\n]+\n\nthis button is broken\n\nImage attached: #{Regex.escape(path)} \(button\.png\)\n/

        assert File.read!(path) == "png-bytes"
        assert Enum.any?(argv, &(&1 =~ "open every one before you judge the message"))
        File.write!(result_path, Jason.encode!(%{"items" => []}))
        {:ok, ""}
      end)

      assert :ok = Triage.triage_thread(thread)
    end

    test "a screenshot with no text reaches the pass as more than an empty message", %{
      workspace: workspace,
      channel: channel,
      thread: thread,
      result_path: result_path
    } do
      stub_slack(
        users: %{"U_PRIYA" => "Priya"},
        files: %{"/files-pri/T1-F_SHOT/button.png" => {"image/png", "png-bytes"}}
      )

      {:ok, thread} =
        Triage.handle_slack_event(
          workspace,
          slack_message_event(channel, %{
            "subtype" => "file_share",
            "ts" => "1790000100.000200",
            "thread_ts" => thread.external_id,
            "text" => "",
            "files" => [
              %{
                "id" => "F_SHOT",
                "name" => "button.png",
                "mimetype" => "image/png",
                "url_private" => "https://files.slack.com/files-pri/T1-F_SHOT/button.png"
              }
            ]
          })
        )

      path = Path.join([Thread.scratch_path(thread), "images", "1790000100.000200-1.png"])

      expect(Tools, :run_agent, fn _backend, argv, _opts ->
        read = thread |> Thread.scratch_path() |> Path.join("thread.md") |> File.read!()

        assert read =~
                 ~r/### 1790000100\.000200 · Priya · [^\n]+\n\nImage attached: #{Regex.escape(path)} \(button\.png\)\n/

        assert Enum.any?(argv, &(&1 =~ "never mark it as needing no response for having no text"))
        assert Enum.any?(argv, &(&1 =~ "asks and reports nothing, in its text or its images"))
        File.write!(result_path, Jason.encode!(%{"items" => []}))
        {:ok, ""}
      end)

      assert :ok = Triage.triage_thread(thread)
    end

    test "an earlier message's image, read back from Slack, is tied to that message", %{
      workspace: workspace,
      channel: channel
    } do
      {:ok, thread} =
        Triage.handle_slack_event(
          workspace,
          slack_message_event(channel, %{
            "ts" => "1790000700.000200",
            "thread_ts" => "1790000600.000100",
            "text" => "Same for me"
          })
        )

      stub_slack(
        users: %{"U_PRIYA" => "Priya"},
        files: %{"/files-pri/T1-F_FORM/form.jpg" => {"image/jpeg", "jpeg-bytes"}},
        replies: [
          %{
            "ts" => "1790000600.000100",
            "user" => "U_PRIYA",
            "text" => "The form will not submit",
            "files" => [
              %{
                "id" => "F_FORM",
                "name" => "form.jpg",
                "mimetype" => "image/jpeg",
                "url_private" => "https://files.slack.com/files-pri/T1-F_FORM/form.jpg"
              }
            ]
          },
          %{
            "ts" => "1790000700.000200",
            "thread_ts" => "1790000600.000100",
            "user" => "U_PRIYA",
            "text" => "Same for me"
          }
        ]
      )

      path = Path.join([Thread.scratch_path(thread), "images", "1790000600.000100-1.jpg"])

      expect(Tools, :run_agent, fn _backend, _argv, _opts ->
        read = thread |> Thread.scratch_path() |> Path.join("thread.md") |> File.read!()

        assert read =~
                 ~r/### 1790000600\.000100 · Priya · [^\n]+\n\nThe form will not submit\n\nImage attached: #{Regex.escape(path)} \(form\.jpg\)\n\n### 1790000700\.000200 · Priya · [^\n]+\n\nSame for me\n$/

        assert File.read!(path) == "jpeg-bytes"
        thread |> Thread.scratch_path() |> Path.join("result.json") |> File.write!(Jason.encode!(%{"items" => []}))
        {:ok, ""}
      end)

      assert :ok = Triage.triage_thread(thread)
    end

    test "an image the Slack app cannot read is named as unread, and the pass runs without an error", %{
      workspace: workspace,
      channel: channel,
      thread: %{id: thread_id} = thread,
      bug: bug,
      result_path: result_path
    } do
      stub_slack(users: %{"U_PRIYA" => "Priya"}, files: %{})

      {:ok, thread} =
        Triage.handle_slack_event(
          workspace,
          slack_message_event(channel, %{
            "subtype" => "file_share",
            "ts" => "1790000100.000200",
            "thread_ts" => thread.external_id,
            "text" => "this button is broken",
            "files" => [
              %{
                "id" => "F_SHOT",
                "name" => "button.png",
                "mimetype" => "image/png",
                "url_private" => "https://files.slack.com/files-pri/T1-F_SHOT/button.png"
              }
            ]
          })
        )

      expect(Tools, :run_agent, fn _backend, _argv, _opts ->
        read = thread |> Thread.scratch_path() |> Path.join("thread.md") |> File.read!()
        assert read =~ "this button is broken\n\nImage attached, but Rail could not read it: button.png\n"
        File.write!(result_path, Jason.encode!(%{"items" => [bug]}))
        {:ok, ""}
      end)

      assert :ok = Triage.triage_thread(thread)
      assert %Thread{error: nil, status: :waiting} = Repo.get!(Thread, thread_id)
      assert [%Item{key: "stuck-at-design"}] = Repo.all(from i in Item, where: i.thread_id == ^thread_id)
    end

    test "a file Slack withholds is named as an unread attachment", %{
      workspace: workspace,
      channel: channel,
      thread: thread,
      result_path: result_path
    } do
      {:ok, thread} =
        Triage.handle_slack_event(
          workspace,
          slack_message_event(channel, %{
            "subtype" => "file_share",
            "ts" => "1790000100.000200",
            "thread_ts" => thread.external_id,
            "text" => "",
            "files" => [%{"id" => "F_HIDDEN", "file_access" => "check_file_info"}]
          })
        )

      expect(Tools, :run_agent, fn _backend, _argv, _opts ->
        read = thread |> Thread.scratch_path() |> Path.join("thread.md") |> File.read!()
        assert read =~ ~r/### 1790000100\.000200 · [^\n]+\n\nA file was attached, but Rail could not read it\.\n/
        File.write!(result_path, Jason.encode!(%{"items" => []}))
        {:ok, ""}
      end)

      assert :ok = Triage.triage_thread(thread)
    end

    test "a later pass leaves no image behind that the thread no longer has", %{
      workspace: workspace,
      channel: channel,
      thread: thread,
      result_path: result_path
    } do
      parent = %{"ts" => thread.external_id, "user" => "U_PRIYA", "text" => "Approved BILL-88 and it sits at Design."}

      stub_slack(
        users: %{"U_PRIYA" => "Priya"},
        files: %{"/files-pri/T1-F_SHOT/button.png" => {"image/png", "png-bytes"}},
        replies: [
          Map.put(parent, "files", [
            %{
              "id" => "F_SHOT",
              "name" => "button.png",
              "mimetype" => "image/png",
              "url_private" => "https://files.slack.com/files-pri/T1-F_SHOT/button.png"
            }
          ])
        ]
      )

      images = Path.join(Thread.scratch_path(thread), "images")
      %Thread{} = triage_with(thread, %{"items" => []})
      assert [_downloaded] = File.ls!(images)

      reply = %{"ts" => "1790000100.000200", "thread_ts" => thread.external_id, "user" => "U_PRIYA", "text" => "+1"}
      {:ok, thread} = Triage.handle_slack_event(workspace, slack_message_event(channel, reply))
      stub_slack(users: %{"U_PRIYA" => "Priya"}, replies: [parent, reply])

      expect(Tools, :run_agent, fn _backend, _argv, _opts ->
        assert [] = File.ls!(images)
        refute thread |> Thread.scratch_path() |> Path.join("thread.md") |> File.read!() =~ "Image attached"
        File.write!(result_path, Jason.encode!(%{"items" => []}))
        {:ok, ""}
      end)

      assert :ok = Triage.triage_thread(thread)
    end
  end
end
