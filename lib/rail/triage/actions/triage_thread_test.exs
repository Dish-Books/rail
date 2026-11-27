defmodule Rail.Triage.Actions.TriageThreadTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Mcp
  alias Rail.Mcp.Schemas.McpConnection
  alias Rail.Projects
  alias Rail.Roles
  alias Rail.Scope
  alias Rail.Tools
  alias Rail.Triage
  alias Rail.Triage.Schemas.ChatMessage
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

    %{project: project, role: role} = triage_project()

    %{workspace: workspace, channel: channel} =
      connect_slack_channel(project, users: %{"U_PRIYA" => "Priya"}, external: context[:external] == true)

    {:ok, thread} =
      Triage.handle_slack_event(
        workspace,
        slack_message_event(channel, %{
          "text" => "Approved BILL-88 and it sits at Design. Could Up next show wait times?"
        })
      )

    %{project: project, role: role, workspace: workspace, channel: channel, thread: thread}
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
        "priority" => "urgent",
        "estimate" => 3
      }
    }

    request = %{
      "key" => "wait-times",
      "kind" => "feature_request",
      "title" => "Wait time on every Up next row",
      "verdict" => "partly_built",
      "summary" => "Ordered by wait, but rows show none.",
      "evidence" => [%{"file" => "lib/up_next.ex", "lines" => "78", "excerpt" => "row", "holds" => false}],
      "assumptions" => [],
      "issue" => %{"title" => "Show wait times", "description" => "...", "priority" => "low", "estimate" => 2}
    }

    %{bug: bug, request: request, result_path: Path.join(Thread.scratch_path(thread), "result.json")}
  end

  test "a bug report becomes a Waiting bug item with its verdict, evidence and drafts, posting nothing", %{
    thread: %{id: thread_id} = thread,
    bug: bug,
    result_path: result_path
  } do
    scratch = Path.dirname(result_path)

    expect(Tools, :run_agent, fn _role, _argv, opts ->
      # The sandbox may write only the scratch folder, and reads the checkout it starts in.
      assert %{cd: worktree, mounts: [^scratch], read_only_mounts: [worktree]} = Map.new(opts)
      assert worktree =~ ".worktrees/triage-#{thread_id}"

      File.write!(
        result_path,
        Jason.encode!(%{
          "title" => "Tasks stuck at Design",
          "message" => "One bug, confirmed.",
          "reply" => "Thanks Priya, we reproduced this.",
          "items" => [bug]
        })
      )

      {:ok, ""}
    end)

    assert :ok = Triage.triage_thread(thread)

    assert %Thread{
             status: :waiting,
             title: "Tasks stuck at Design",
             error: nil,
             reply_text: "Thanks Priya, we reproduced this.",
             reply_posted_at: nil,
             chat_read_at: %DateTime{},
             permalink: "https://slack.example/" <> _p
           } =
             Repo.get!(Thread, thread_id)

    assert [%ChatMessage{author: :agent, text: "One bug, confirmed.", changes: "Added item 1"}] =
             Repo.all(from c in ChatMessage, where: c.thread_id == ^thread_id)

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
               issue_estimate: 3,
               followup_text: nil,
               ignored: false,
               sent_at: nil,
               created_issue_id: nil
             }
           ] = Repo.all(from i in Item, where: i.thread_id == ^thread_id)
  end

  test "a feature request is stored as one, with how much of it is built", %{
    thread: %{id: thread_id} = thread,
    request: request,
    result_path: result_path
  } do
    expect(Tools, :run_agent, fn _role, _argv, _opts ->
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
    expect(Tools, :run_agent, fn _role, _argv, _opts ->
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

  test "an item an existing issue covers links it by the number the search showed, and drafts no issue",
       %{
         project: project,
         thread: %{id: thread_id} = thread,
         request: request,
         result_path: result_path
       } do
    {:ok, %{id: issue_id, number: number}} =
      Issues.create_issue(system_scope(), project, %{title: "Up next rows show how long each has waited"})

    Repo.update_all(from(i in Issue, where: i.id == ^issue_id), set: [state: :done])

    expect(Tools, :run_agent, fn _role, argv, _opts ->
      brief = Enum.find(argv, &(&1 =~ "Triage the Slack thread in"))
      assert brief =~ "search this project's tickets for one that already covers the item"
      assert brief =~ "Search them with `search_issues`"
      assert brief =~ "Open a likely match with `get_issue`"
      refute brief =~ "Linear"
      refute thread |> Thread.scratch_path() |> Path.join("issues.md") |> File.exists?()
      covered = Map.merge(request, %{"existing_issue" => "#{number}", "followup" => "Priya hit it too, on BILL-88."})
      File.write!(result_path, Jason.encode!(%{"items" => [covered]}))
      {:ok, ""}
    end)

    assert :ok = Triage.triage_thread(thread)

    assert [
             %Item{
               existing_issue_id: ^issue_id,
               issue_title: nil,
               issue_description: nil,
               issue_priority: nil,
               issue_estimate: nil,
               followup_text: "Priya hit it too, on BILL-88."
             }
           ] = Repo.all(from i in Item, where: i.thread_id == ^thread_id)
  end

  test "a pass in an ordinary channel runs the stored triage prompt where the repo has none, and drafts one reply Rail ends with the new tickets' links",
       %{
         thread: thread,
         result_path: result_path
       } do
    expect(Tools, :run_agent, fn _role, argv, _opts ->
      assert ["--append-system-prompt", "You triage."] in Enum.chunk_every(argv, 2, 1)
      brief = Enum.find(argv, &(&1 =~ "Triage the Slack thread in"))
      assert brief =~ "Rail ends it with the links of the tickets it creates"
      assert brief =~ "the reply says the item is already tracked in that issue, giving its identifier"
      assert brief =~ "An issue's `title` states the behavior the product should have"
      refute brief =~ "external"
      File.write!(result_path, Jason.encode!(%{"items" => []}))
      {:ok, ""}
    end)

    assert :ok = Triage.triage_thread(thread)
  end

  @tag :external
  test "a pass in an external channel drafts replies that neither link nor name an issue, even one tracking it", %{
    thread: thread,
    result_path: result_path
  } do
    expect(Tools, :run_agent, fn _role, argv, _opts ->
      brief = Enum.find(argv, &(&1 =~ "Triage the Slack thread in"))
      assert brief =~ "channel is external, shared with people outside the team"
      assert brief =~ "the reply says the item is already tracked, without naming the issue or its identifier"
      assert brief =~ "Still fill in `existing_issue`"
      refute brief =~ "Rail ends it with the links"
      refute brief =~ "giving its identifier"
      File.write!(result_path, Jason.encode!(%{"items" => []}))
      {:ok, ""}
    end)

    assert :ok = Triage.triage_thread(thread)
  end

  test "a bug and an unrelated request become two items, each linked from its passage", %{
    thread: %{id: thread_id, external_id: ts} = thread,
    bug: bug,
    request: request,
    result_path: result_path
  } do
    expect(Tools, :run_agent, fn _role, _argv, _opts ->
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

  test "a later message widens an item by its key, adds a new one, and leaves closed items alone", %{
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

    expect(Tools, :run_agent, fn _role, _argv, _opts ->
      File.write!(result_path, Jason.encode!(%{"items" => [bug, fixed]}))
      {:ok, ""}
    end)

    assert :ok = Triage.triage_thread(thread)
    # As a Send leaves it: that round is over.
    Repo.update_all(from(i in Item, where: i.key == "switcher-resets"), set: [sent_at: DateTime.utc_now()])

    {:ok, thread} =
      Triage.handle_slack_event(
        workspace,
        slack_message_event(channel, %{
          "ts" => "1790000100.000200",
          "thread_ts" => thread.external_id,
          "text" => "Same on BILL-91. Also the export is gone."
        })
      )

    expect(Tools, :run_agent, fn _role, _argv, _opts ->
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

    expect(Tools, :run_agent, fn _role, _argv, _opts ->
      assert thread |> Thread.scratch_path() |> Path.join("thread.md") |> File.read!() =~ "PostHog (bot)"

      thread
      |> Thread.scratch_path()
      |> Path.join("result.json")
      |> File.write!(Jason.encode!(%{"reply" => nil, "items" => [bug]}))

      {:ok, ""}
    end)

    assert :ok = Triage.triage_thread(thread)

    assert [%Item{kind: :bug, issue_title: "Approve leaves tasks at Design"}] =
             Repo.all(from i in Item, where: i.thread_id == ^thread_id)

    assert %Thread{reply_text: nil} = Repo.get!(Thread, thread_id)
  end

  test "the agent runs in a checkout of the default branch, removed after, with an MCP token the thread holds meanwhile",
       %{
         project: %{id: project_id, clone_path: clone_path} = project,
         thread: %{id: thread_id} = thread,
         role: %{id: role_id},
         result_path: result_path
       } do
    worktree = Thread.worktree_path(%{thread | project: project})
    expect(Git, :checkout_detached_worktree, fn %{id: ^project_id}, ^worktree -> {:ok, worktree} end)

    expect(Tools, :run_agent, fn %{id: ^role_id}, argv, opts ->
      assert %{"RAIL_MCP_TOKEN" => token} = opts[:env]
      assert opts[:timeout] == to_timeout(minute: 30)
      assert opts[:cd] == worktree
      assert Enum.any?(argv, &(&1 =~ result_path))

      hash = :crypto.hash(:sha256, token)
      assert %Thread{mcp_token_hash: ^hash, triage_started_at: %DateTime{}} = Repo.get!(Thread, thread_id)

      File.write!(result_path, Jason.encode!(%{"items" => []}))
      {:ok, ""}
    end)

    expect(Git, :remove_worktree, fn ^clone_path, ^worktree -> :ok end)

    assert :ok = Triage.triage_thread(thread)
    assert %Thread{mcp_token_hash: nil, triage_started_at: nil} = Repo.get!(Thread, thread_id)
  end

  test "the agent runs the triage prompt merged to the project's .rail/prompts", %{
    project: %{id: project_id},
    thread: thread,
    result_path: result_path
  } do
    expect(Git, :read_default_branch_file, fn %{id: ^project_id}, ".rail/prompts/triage.md" ->
      {:ok, "From the repo.\n"}
    end)

    expect(Tools, :run_agent, fn _role, argv, _opts ->
      assert ["--append-system-prompt", "From the repo."] in Enum.chunk_every(argv, 2, 1)
      File.write!(result_path, Jason.encode!(%{"items" => []}))
      {:ok, ""}
    end)

    assert :ok = Triage.triage_thread(thread)
  end

  test "a pass held by another snoozes", %{thread: thread, result_path: result_path} do
    expect(Tools, :run_agent, fn _role, _argv, _opts ->
      assert {:snooze, 30} = Triage.triage_thread(thread)
      File.write!(result_path, Jason.encode!(%{"items" => []}))
      {:ok, ""}
    end)

    assert :ok = Triage.triage_thread(thread)
  end

  test "a pass whose MCP server does not answer snoozes without failing, and runs once it does", %{
    project: project,
    thread: %{id: thread_id} = thread,
    role: role,
    result_path: result_path
  } do
    {:ok, server} = Mcp.create_server(system_scope(), %{name: "tt_down", url: "https://down.example.com/mcp"})
    {:ok, _role} = Roles.update_role(system_scope(), role, %{mcp_tools: ["tt_down__list_issues"]})
    {:ok, user} = Users.register_oauth_user(%{github_id: "gh_td", login: "td", email: "td@example.com"})
    {:ok, _project} = Projects.update_project(system_scope(), project, %{"triage_user_id" => user.id})
    Repo.insert!(%McpConnection{user_id: user.id, mcp_server_id: server.id, access_token: "at_td"})

    Req.Test.stub(Mcp, &Plug.Conn.send_resp(&1, 500, "down"))

    assert {:snooze, 30} = Triage.triage_thread(thread)
    assert %Thread{status: :triaging, error: nil, triage_started_at: nil} = Repo.get!(Thread, thread_id)

    Req.Test.stub(Mcp, fn conn ->
      case conn |> Req.Test.raw_body() |> Jason.decode!() do
        %{"method" => "notifications/initialized"} -> Plug.Conn.send_resp(conn, 202, "")
        %{"id" => id} -> Req.Test.json(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => %{}})
      end
    end)

    expect(Tools, :run_agent, fn _role, _argv, _opts ->
      File.write!(result_path, Jason.encode!(%{"items" => []}))
      {:ok, ""}
    end)

    assert :ok = Triage.triage_thread(thread)
    assert %Thread{error: nil} = Repo.get!(Thread, thread_id)
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

    expect(Tools, :run_agent, fn _role, _argv, _opts ->
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

    test "when the role's MCP servers need reconnecting", %{
      project: project,
      thread: %{id: thread_id} = thread,
      role: role
    } do
      {:ok, _server} =
        Mcp.create_server(system_scope(), %{
          name: "tt_linear",
          url: "https://linear.example.com/mcp",
          token_endpoint: "https://auth.example.com/token",
          client_id: "client_1"
        })

      {:ok, _role} = Roles.update_role(system_scope(), role, %{mcp_tools: ["tt_linear__list_issues"]})
      reject(&Tools.run_agent/3)

      assert :ok = Triage.triage_thread(thread)

      assert %Thread{error: "This project has no triage user to reach tt_linear as." <> _pick} =
               Repo.get!(Thread, thread_id)

      {:ok, user} = Users.register_oauth_user(%{github_id: "gh_tt", login: "tt", email: "tt@example.com"})
      {:ok, _project} = Projects.update_project(system_scope(), project, %{"triage_user_id" => user.id})

      assert :ok = Triage.triage_thread(thread)

      assert %Thread{
               error:
                 "tt_linear needs reconnecting for tt. Reconnect it under Settings → Connected accounts, " <>
                   "then ask the agent in the chat to try again."
             } = Repo.get!(Thread, thread_id)
    end

    test "when the agent fails, times out or is not dispatched", %{thread: %{id: thread_id} = thread} do
      for {outcome, error} <- [
            {{:error, {:exit, 2, "broke\n"}}, "Triage exited with code 2."},
            {{:error,
              {:exit, 1,
               ~s({"type":"result","is_error":true,"error":"authentication_failed",) <>
                 ~s("result":"Failed to authenticate: OAuth session expired and could not be refreshed"}\n)}},
             "Triage exited with code 1: Failed to authenticate: OAuth session expired and could not be refreshed. " <>
               "Sign the backend in again under Settings → Backends."},
            {{:error, :timeout}, "Triage was still running after 30 minutes, so it was stopped."},
            {{:error, :dispatch_disabled}, "Dispatch is switched off, so triage did not run."},
            {{:error, :backend_signed_out},
             "The Triage role's backend is signed out, so triage did not run. " <>
               "Sign it in under Settings → Backends, then ask the agent in the chat to try again."}
          ] do
        expect(Tools, :run_agent, fn _role, _argv, _opts -> outcome end)

        assert :ok = Triage.triage_thread(thread)
        assert %Thread{error: ^error} = Repo.get!(Thread, thread_id)
      end
    end

    test "when the code cannot be checked out, in git's words or GitHub's", %{
      thread: %{id: thread_id} = thread
    } do
      reject(&Tools.run_agent/3)

      for {failure, error} <- [
            {"fatal: 'origin' does not appear to be a git repository",
             "fatal: 'origin' does not appear to be a git repository"},
            {{:github_api_error, 500, "down"}, ~s(Triage failed: {:github_api_error, 500, "down"})}
          ] do
        expect(Git, :checkout_detached_worktree, fn _project, _worktree_path -> {:error, failure} end)

        assert :ok = Triage.triage_thread(thread)
        assert %Thread{error: ^error} = Repo.get!(Thread, thread_id)
      end
    end

    test "when the result is missing or malformed", %{thread: %{id: thread_id} = thread, result_path: result_path} do
      expect(Tools, :run_agent, fn _role, _argv, _opts ->
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

    expect(Tools, :run_agent, fn _role, _argv, _opts ->
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
    %Thread{items: [_item]} = triage_with(thread, %{"reply" => "Reproduced.", "items" => [bug]})

    {:ok, thread} =
      Triage.handle_slack_event(
        workspace,
        slack_message_event(channel, %{"ts" => "1790000100.000200", "thread_ts" => thread.external_id, "text" => "+1"})
      )

    expect(Tools, :run_agent, fn _role, _argv, _opts ->
      rewritten =
        Map.put(bug, "issue", %{
          "title" => "Rail's new title",
          "description" => "New.",
          "priority" => "low",
          "estimate" => 5
        })

      File.write!(
        result_path,
        Jason.encode!(%{"message" => "Redrafted.", "reply" => "Couldn't reproduce yet.", "items" => [rewritten]})
      )

      {:ok, ""}
    end)

    assert :ok = Triage.triage_thread(thread)
    assert %Thread{reply_text: "Couldn't reproduce yet."} = Repo.get!(Thread, thread_id)

    assert [%ChatMessage{changes: "Edited the reply · Edited item 1"}] =
             Repo.all(from c in ChatMessage, where: c.thread_id == ^thread_id)

    assert [
             %Item{
               issue_title: "Rail's new title",
               issue_description: "New.",
               issue_priority: :low,
               issue_estimate: 5
             }
           ] = Repo.all(from i in Item, where: i.thread_id == ^thread_id)
  end

  test "a later pass never changes a ticket Send created", %{
    project: project,
    workspace: workspace,
    channel: channel,
    thread: %{id: thread_id} = thread,
    bug: bug,
    result_path: result_path
  } do
    thread = triage_with(thread, %{"items" => [bug]})
    {:ok, user} = Users.update_user(system_scope(), slack_user(workspace.external_id), %{project_ids: [project.id]})

    assert {:ok, %Thread{status: :done}} = Triage.send_triage_reply(Scope.for_user(user), thread)

    {:ok, thread} =
      Triage.handle_slack_event(
        workspace,
        slack_message_event(channel, %{"ts" => "1790000100.000300", "thread_ts" => thread.external_id, "text" => "+1"})
      )

    expect(Tools, :run_agent, fn _role, _argv, _opts ->
      draft = thread |> Thread.scratch_path() |> Path.join("draft.json") |> File.read!() |> Jason.decode!()
      assert %{"items" => [%{"key" => "stuck-at-design", "state" => "closed: never restate it"}]} = draft
      redrafted = Map.merge(bug, %{"summary" => "Redrafted.", "issue" => %{"title" => "Redrafted", "estimate" => 8}})
      File.write!(result_path, Jason.encode!(%{"items" => [redrafted]}))
      {:ok, ""}
    end)

    assert :ok = Triage.triage_thread(thread)

    assert [
             %Item{
               summary: "enter_stage writes the stage, then the role lookup raises.",
               issue_title: "Approve leaves tasks at Design",
               created_issue_id: "iss_" <> _created,
               sent_at: %DateTime{}
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

      expect(Tools, :run_agent, fn _role, argv, _opts ->
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

      expect(Tools, :run_agent, fn _role, argv, _opts ->
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

      expect(Tools, :run_agent, fn _role, _argv, _opts ->
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

      expect(Tools, :run_agent, fn _role, _argv, _opts ->
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

      expect(Tools, :run_agent, fn _role, _argv, _opts ->
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

      expect(Tools, :run_agent, fn _role, _argv, _opts ->
        assert [] = File.ls!(images)
        refute thread |> Thread.scratch_path() |> Path.join("thread.md") |> File.read!() =~ "Image attached"
        File.write!(result_path, Jason.encode!(%{"items" => []}))
        {:ok, ""}
      end)

      assert :ok = Triage.triage_thread(thread)
    end
  end

  test "the brief carries the rules retrieved with the thread's text, and nothing is logged", %{
    project: project,
    thread: thread,
    result_path: result_path
  } do
    stub_vertex(%{"wait times" => vector([1.0])})

    learning(
      project,
      %{
        rule: "Up next is ordered by wait; that is expected",
        why: "Decided on RAIL-12",
        kind: :product,
        roles: [:triage]
      },
      embedding: [1.0]
    )

    expect(Tools, :run_agent, fn _role, argv, _opts ->
      prompt = Enum.join(argv, " ")
      assert prompt =~ "What this project has learned"
      assert prompt =~ "- Product: Up next is ordered by wait; that is expected Why: Decided on RAIL-12"
      File.write!(result_path, Jason.encode!(%{"items" => []}))
      {:ok, ""}
    end)

    assert :ok = Triage.triage_thread(thread)
    assert_received {:embedded, "Approved BILL-88" <> _rest, "RETRIEVAL_QUERY"}
    assert [] = Repo.all(Rail.Learnings.Schemas.LearningRetrieval)
  end

  test "a pass that waits for usage lets go of its thread with no error, and says when to come back", %{
    thread: %{id: thread_id} = thread
  } do
    reset = DateTime.shift(DateTime.utc_now(), hour: 2)
    expect(Tools, :run_agent, fn _role, _argv, _opts -> {:error, {:waiting_for_usage, reset}} end)

    assert {:waiting_for_usage, ^reset} = Triage.triage_thread(thread)
    assert %Thread{error: nil, triage_started_at: nil, mcp_token_hash: nil} = Repo.get!(Thread, thread_id)
  end

  test "a pass no signed-in account can run says so, as a run would", %{thread: %{id: thread_id} = thread} do
    error =
      "No signed-in account offers claude-opus-5-5. Sign one in on Settings › Backends, or pick another model for Triage."

    expect(Tools, :run_agent, fn _role, _argv, _opts -> {:error, error} end)

    assert :ok = Triage.triage_thread(thread)
    assert %Thread{error: ^error} = Repo.get!(Thread, thread_id)
  end

  describe "a chat line" do
    setup %{project: project, workspace: workspace, thread: thread, bug: bug, request: request} do
      dup = Map.merge(bug, %{"key" => "stuck-again", "title" => "Stuck again", "issue" => %{"title" => "Dup"}})
      noise = Map.merge(bug, %{"key" => "fix-enabled", "title" => "Fix stays enabled", "issue" => %{"title" => "Fix"}})
      thread = triage_with(thread, triage_result([bug, request, dup, noise]))
      user = slack_user(workspace.external_id, "Michael Chen")
      {:ok, user} = Users.update_user(system_scope(), user, %{project_ids: [project.id]})
      scope = Scope.for_user(user)
      [_bug, sent, dup_item, ignored] = thread.items

      # As a Send leaves it: that item's round is over.
      Repo.update_all(from(i in Item, where: i.id == ^sent.id), set: [sent_at: DateTime.utc_now()])
      {:ok, _ignored} = Triage.update_triage_item(scope, ignored, %{"ignored" => "true"})
      {:ok, _kind} = Triage.update_triage_item(scope, dup_item, %{"kind" => "feature_request"})
      {:ok, _reply} = Triage.update_triage_reply(scope, thread, %{"reply_text" => "Typed by Michael."})

      %{thread: thread, scope: scope}
    end

    test "runs a pass that reads the draft and the chat, and changes only what it asks", %{
      thread: %{id: thread_id} = thread,
      scope: scope,
      bug: bug,
      request: request,
      result_path: result_path
    } do
      assert {:ok, %ChatMessage{author: :person, text: "Drop item 3."}} =
               Triage.send_triage_chat(scope, thread, %{"text" => "Drop item 3."})

      assert %Thread{status: :triaging} = Repo.get!(Thread, thread_id)

      expect(Tools, :run_agent, fn _role, _argv, _opts ->
        dir = Thread.scratch_path(thread)
        assert File.read!(Path.join(dir, "chat.md")) =~ "### Michael Chen\n\nDrop item 3."

        assert %{
                 "reply" => "Typed by Michael.",
                 "reply_posted" => false,
                 "items" => [
                   %{
                     "key" => "stuck-at-design",
                     "position" => 1,
                     "state" => "open",
                     "verdict" => "confirmed",
                     "evidence" => [%{"file" => "lib/enter_stage.ex", "lines" => "42-45"}],
                     "assumptions" => [%{"text" => "Billing is the BILL project."}]
                   },
                   %{"key" => "wait-times", "state" => "closed: never restate it"},
                   %{"key" => "stuck-again", "kind" => "feature_request", "verdict" => nil},
                   %{
                     "key" => "fix-enabled",
                     "state" => "ignored by a teammate: restate it unchanged unless the chat asks"
                   }
                 ]
               } = dir |> Path.join("draft.json") |> File.read!() |> Jason.decode!()

        rewritten = Map.put(request, "summary", "A pass must not touch a closed item.")

        File.write!(
          result_path,
          Jason.encode!(triage_result([bug, rewritten], %{"message" => "Dropped item 3.", "reply" => nil}))
        )

        {:ok, ""}
      end)

      assert :ok = Triage.triage_thread(thread)

      assert %Thread{status: :waiting, error: nil, reply_text: "Typed by Michael."} = Repo.get!(Thread, thread_id)

      assert [
               %Item{key: "stuck-at-design", position: 1, evidence: [%Item.Evidence{lines: "42-45"}]},
               %Item{key: "wait-times", position: 2, summary: "Ordered by wait, but rows show none."},
               %Item{key: "fix-enabled", position: 4, ignored: true}
             ] = Repo.all(from i in Item, where: i.thread_id == ^thread_id, order_by: i.position)

      assert [
               %ChatMessage{author: :agent},
               %ChatMessage{author: :person},
               %ChatMessage{author: :agent, text: "Dropped item 3.", changes: "Removed item 3"}
             ] = Repo.all(from c in ChatMessage, where: c.thread_id == ^thread_id, order_by: [c.inserted_at, c.id])

      assert {:ok, %Thread{status: :waiting}} = Triage.get_triage_thread(scope, thread_id)
    end

    test "a result with an item Rail cannot read fails the pass and keeps every card", %{
      thread: %{id: thread_id} = thread,
      scope: scope,
      bug: bug,
      result_path: result_path
    } do
      {:ok, _line} = Triage.send_triage_chat(scope, thread, %{"text" => "Merge 1 and 3."})
      before = Repo.all(from i in Item, where: i.thread_id == ^thread_id, order_by: i.position)

      expect(Tools, :run_agent, fn _role, _argv, _opts ->
        unreadable = Map.put(bug, "key", "Bad Key")
        File.write!(result_path, Jason.encode!(triage_result([bug, unreadable])))
        {:ok, ""}
      end)

      assert :ok = Triage.triage_thread(thread)

      assert %Thread{
               status: :waiting,
               error: "Triage listed an item Rail could not read: Bad Key. The draft is as it was.",
               reply_text: "Typed by Michael."
             } = Repo.get!(Thread, thread_id)

      assert ^before = Repo.all(from i in Item, where: i.thread_id == ^thread_id, order_by: i.position)
    end

    test "a line sent while a pass runs gets a pass of its own", %{
      thread: %{id: thread_id} = thread,
      scope: scope,
      bug: bug,
      result_path: result_path
    } do
      {:ok, _line} = Triage.send_triage_chat(scope, thread, %{"text" => "Shorter reply."})
      Phoenix.PubSub.subscribe(Rail.PubSub, "triage")

      expect(Tools, :run_agent, fn _role, _argv, _opts ->
        {:ok, _line} = Triage.send_triage_chat(scope, thread, %{"text" => "And item 1 is low."})
        File.write!(result_path, Jason.encode!(triage_result([bug], %{"reply" => "Shorter."})))
        {:ok, ""}
      end)

      assert :ok = Triage.triage_thread(thread)
      assert_received {:triage_scheduled, ^thread_id, 0}
      assert_received {:triage_scheduled, ^thread_id, 0}
      assert %Thread{status: :triaging} = settled = Repo.get!(Thread, thread_id)
      assert Thread.chat_owed?(Repo.preload(settled, :chat_messages))

      expect(Tools, :run_agent, fn _role, _argv, _opts ->
        assert thread |> Thread.scratch_path() |> Path.join("chat.md") |> File.read!() =~ "And item 1 is low."
        File.write!(result_path, Jason.encode!(triage_result([bug], %{"reply" => "Shorter."})))
        {:ok, ""}
      end)

      assert :ok = Triage.triage_thread(thread)
      assert %Thread{status: :waiting} = Repo.get!(Thread, thread_id)
    end

    test "a pass whose result meets a Send writes nothing, records no error and is tried again", %{
      thread: %{id: thread_id} = thread,
      scope: scope,
      result_path: result_path
    } do
      {:ok, _line} = Triage.send_triage_chat(scope, thread, %{"text" => "Drop everything."})
      before = Repo.all(from i in Item, where: i.thread_id == ^thread_id, order_by: i.position)

      expect(Tools, :run_agent, fn _role, _argv, _opts ->
        Repo.update_all(from(t in Thread, where: t.id == ^thread_id), set: [send_started_at: DateTime.utc_now()])
        File.write!(result_path, Jason.encode!(triage_result([], %{"reply" => "Gone."})))
        {:ok, ""}
      end)

      assert {:snooze, 30} = Triage.triage_thread(thread)
      assert %Thread{error: nil, reply_text: "Typed by Michael.", triage_started_at: nil} = Repo.get!(Thread, thread_id)
      assert ^before = Repo.all(from i in Item, where: i.thread_id == ^thread_id, order_by: i.position)
      assert 1 = Repo.aggregate(from(c in ChatMessage, where: c.thread_id == ^thread_id and c.author == :agent), :count)
    end
  end

  test "after a reply is posted, a thanks keeps it, and a newer question opens a new round", %{
    workspace: workspace,
    channel: channel,
    thread: %{id: thread_id} = thread,
    bug: bug,
    result_path: result_path
  } do
    thread = triage_with(thread, triage_result([bug]))
    %{id: user_id} = slack_user(workspace.external_id)
    posted_at = ~U[2026-09-01 10:00:00.000000Z]
    # As a Send leaves the thread, posted before the messages below.
    Repo.update_all(from(t in Thread, where: t.id == ^thread_id),
      set: [reply_posted_at: posted_at, reply_posted_by_id: user_id]
    )

    Repo.update_all(from(i in Item, where: i.thread_id == ^thread_id), set: [sent_at: posted_at])

    {:ok, thread} =
      Triage.handle_slack_event(
        workspace,
        slack_message_event(channel, %{"ts" => "1790000100.000400", "thread_ts" => thread.external_id, "text" => "thanks"})
      )

    expect(Tools, :run_agent, fn _role, _argv, _opts ->
      File.write!(result_path, Jason.encode!(triage_result([], %{"reply" => nil, "message" => "Nothing to do."})))
      {:ok, ""}
    end)

    assert :ok = Triage.triage_thread(thread)

    assert %Thread{
             status: :done,
             reply_text: "Thanks Priya, we reproduced this and filed it.",
             reply_posted_at: ^posted_at,
             reply_posted_by_id: ^user_id
           } = Repo.get!(Thread, thread_id)

    assert [%ChatMessage{changes: nil}] =
             Repo.all(from c in ChatMessage, where: c.thread_id == ^thread_id and c.text == "Nothing to do.")

    {:ok, thread} =
      Triage.handle_slack_event(
        workspace,
        slack_message_event(channel, %{"ts" => "1790000200.000400", "thread_ts" => thread.external_id, "text" => "When?"})
      )

    expect(Tools, :run_agent, fn _role, _argv, _opts ->
      File.write!(result_path, Jason.encode!(triage_result([bug], %{"reply" => "No date yet."})))
      {:ok, ""}
    end)

    assert :ok = Triage.triage_thread(thread)

    assert %Thread{status: :waiting, reply_text: "No date yet.", reply_posted_at: nil, reply_posted_by_id: nil} =
             Repo.get!(Thread, thread_id)

    # Posted again, a chat pass that drafts a reply with nothing newer in the thread keeps what Slack has.
    Repo.update_all(from(t in Thread, where: t.id == ^thread_id),
      set: [reply_posted_at: DateTime.utc_now(), reply_posted_by_id: user_id]
    )

    unique = System.unique_integer([:positive])

    {:ok, nameless} =
      Users.register_oauth_user(%{github_id: "nl_#{unique}", login: "nl_#{unique}", email: "nl_#{unique}@x.com"})

    {:ok, nameless} = Users.update_user(system_scope(), nameless, %{project_ids: [thread.project_id]})

    {:ok, gone} =
      Users.register_oauth_user(%{github_id: "go_#{unique}", login: "go_#{unique}", email: "go_#{unique}@x.com"})

    {:ok, gone} = Users.update_user(system_scope(), gone, %{project_ids: [thread.project_id]})
    {:ok, _line} = Triage.send_triage_chat(Scope.for_user(nameless), thread, %{"text" => "Anything else?"})
    {:ok, _line} = Triage.send_triage_chat(Scope.for_user(gone), thread, %{"text" => "Me too."})
    Repo.delete!(gone)

    expect(Tools, :run_agent, fn _role, _argv, _opts ->
      chat = thread |> Thread.scratch_path() |> Path.join("chat.md") |> File.read!()
      assert chat =~ "### nl_#{unique}\n\nAnything else?"
      assert chat =~ "### A teammate\n\nMe too."
      File.write!(result_path, Jason.encode!(triage_result([bug], %{"reply" => "A second reply."})))
      {:ok, ""}
    end)

    assert :ok = Triage.triage_thread(thread)
    assert %Thread{reply_text: "No date yet.", reply_posted_at: %DateTime{}} = Repo.get!(Thread, thread_id)

    assert [%Item{sent_at: ^posted_at}] = Repo.all(from i in Item, where: i.thread_id == ^thread_id)
  end
end
