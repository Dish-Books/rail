defmodule Rail.Mcp.Actions.CallRunToolTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Mcp
  alias Rail.Mcp.RunContext
  alias Rail.Mcp.Schemas.McpConnection
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Tools.Schemas.OsProcess
  alias Rail.Users

  # The smallest part of a plan the structure allows, trimmed as a save trims it.
  @part String.trim("""
        ## Implementation plan

        ### Approach

        Build it.

        No diagrams: one module changes.

        ### File-level changes

        - `lib/rail.ex`: builds it.

        ### Verification

        - `lib/rail_test.exs`: covers it.
        """)

  # The smallest plan the structure allows: no diagrams, so Approach says why, and no Program design.
  @plan """
  ## Implementation plan

  ### Approach

  Extend the module.

  No diagrams: one module changes.

  ### File-level changes

  - `lib/rail.ex`: extends the module.

  ### Verification

  - `lib/rail_test.exs`: covers the extension.
  """

  setup do
    id = System.unique_integer([:positive])

    {:ok, user} =
      Users.register_oauth_user(%{github_id: "crt_gh_#{id}", login: "crt_#{id}", email: "crt_#{id}@example.com"})

    {:ok, linear} =
      Mcp.create_server(system_scope(), %{
        name: "crt_linear",
        url: "https://linear.example.com/mcp",
        token_endpoint: "https://auth.example.com/token",
        client_id: "client_1"
      })

    Repo.insert!(%McpConnection{
      user_id: user.id,
      mcp_server_id: linear.id,
      access_token: "at_old",
      refresh_token: "rt_1",
      expires_at: DateTime.shift(DateTime.utc_now(), hour: 1)
    })

    {:ok, _open} =
      Mcp.create_server(system_scope(), %{
        name: "crt_open",
        url: "https://open.example.com/mcp",
        auth: :none
      })

    {:ok, _off} =
      Mcp.create_server(system_scope(), %{
        name: "crt_off",
        url: "https://off.example.com/mcp",
        auth: :none,
        enabled: false
      })

    Req.Test.stub(Mcp, fn conn ->
      cond do
        conn.host == "auth.example.com" ->
          Req.Test.json(conn, %{"access_token" => "at_new"})

        Plug.Conn.get_req_header(conn, "authorization") == ["Bearer at_old"] ->
          Plug.Conn.send_resp(conn, 401, "")

        true ->
          case conn |> Req.Test.raw_body() |> Jason.decode!() do
            %{"method" => "notifications/initialized"} ->
              Plug.Conn.send_resp(conn, 202, "")

            %{"method" => "initialize", "id" => id} ->
              Req.Test.json(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => %{}})

            %{"method" => "tools/call", "id" => id, "params" => params} ->
              Req.Test.json(conn, %{
                "jsonrpc" => "2.0",
                "id" => id,
                "result" => %{"content" => [%{"type" => "text", "text" => Jason.encode!(params)}]}
              })
          end
      end
    end)

    context = %RunContext{role: %Role{mcp_tools: ["crt_linear__get_issue", "crt_open__*", "crt_off__*"]}, user: user}

    %{context: context}
  end

  test "forwards an allowed call to its server under the tool's own name", %{context: context} do
    expected = Jason.encode!(%{"name" => "echo", "arguments" => %{}})

    assert {:ok, %{"content" => [%{"text" => ^expected}]}} = Mcp.call_run_tool(context, "crt_open__echo", nil)
  end

  test "refreshes the assignee's rejected token and retries", %{context: context} do
    expected = Jason.encode!(%{"name" => "get_issue", "arguments" => %{"id" => "RAIL-1"}})

    assert {:ok, %{"content" => [%{"text" => ^expected}]}} =
             Mcp.call_run_tool(context, "crt_linear__get_issue", %{"id" => "RAIL-1"})
  end

  test "refuses names the role does not allow or that reach no enabled server", %{context: context} do
    assert {:error, :unknown_tool} = Mcp.call_run_tool(context, "crt_linear__delete_issue", %{})
    assert {:error, :unknown_tool} = Mcp.call_run_tool(context, "no_prefix", %{})
    assert {:error, :unknown_tool} = Mcp.call_run_tool(context, "crt_off__anything", %{})
    assert {:error, :unknown_tool} = Mcp.call_run_tool(context, nil, %{})
  end

  test "a triage pass calls only what an admin allowed its role, on the triage user's connection", %{
    context: %{user: user},
    project: project
  } do
    assert {:ok, %Role{mcp_tools: []} = triage} = Roles.get_role(project_id: project.id, stage: :triage)
    assert {:error, :unknown_tool} = Mcp.call_run_tool(%RunContext{role: triage, user: user}, "crt_open__echo", %{})

    {:ok, allowed} = Roles.update_role(system_scope(), triage, %{mcp_tools: ["crt_linear__get_issue"]})
    context = %RunContext{os_process: nil, role: allowed, user: user}
    expected = Jason.encode!(%{"name" => "get_issue", "arguments" => %{"id" => "RAIL-1"}})

    assert {:ok, %{"content" => [%{"text" => ^expected}]}} =
             Mcp.call_run_tool(context, "crt_linear__get_issue", %{"id" => "RAIL-1"})

    assert {:error, :unknown_tool} = Mcp.call_run_tool(context, "crt_open__echo", %{})
  end

  describe "the save tools Rail serves each stage" do
    setup %{project: project} do
      Req.Test.expect(Rail.Linear, fn conn ->
        Req.Test.json(conn, %{
          "data" => %{
            "issueCreate" => %{
              "success" => true,
              "issue" => %{"id" => "lin_crs_1", "identifier" => "CRS-1", "title" => "Call Run Save"}
            }
          }
        })
      end)

      {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Call Run Save"})
      {:ok, task} = Pipeline.create_task(issue, :review)
      on_exit(fn -> File.rm_rf(task.scratch_path) end)

      {:ok, role} = Roles.get_role(project_id: project.id, stage: :review_lead)

      {:ok, run} =
        Pipeline.create_run(%{task_id: task.id, role_id: role.id, status: :running, started_at: DateTime.utc_now()})

      os_process =
        Repo.insert!(%OsProcess{
          run_id: run.id,
          task_id: task.id,
          stream_path: Path.join(task.scratch_path, "stream.ndjson"),
          status: :running,
          started_at: DateTime.utc_now()
        })

      finding = %{
        "key" => "round-query-scope",
        "kind" => "code",
        "raised_by" => "code_reviewer",
        "title" => "The round reads other tasks",
        "problem" => "The query has no task filter.",
        "file" => "lib/a.ex",
        "line" => 88,
        "fix" => "Scope the query to the task.",
        "why" => "Another task's rows leak in.",
        "rule" => "Every query is scoped to its task.",
        "severity" => "minor",
        "recommendation" => "fix",
        "places" => [%{"file" => "lib/a.ex", "line" => 88, "label" => "list/1"}],
        "evidence" => [%{"name" => "The query", "kind" => "code", "file" => "lib/a.ex", "line" => 88}]
      }

      %{task: task, run: run, finding: finding, lead: %RunContext{os_process: os_process, role: role, user: nil}}
    end

    test "a Review lead run calling another stage's save tool is told there is no such tool", %{lead: lead} do
      assert {:error, :unknown_tool} = Mcp.call_run_tool(lead, "save_ticket", %{"title" => "T", "description" => "D"})
    end

    test "a malformed finding is refused naming each field, and the corrected call is saved", %{
      lead: lead,
      finding: finding,
      task: task
    } do
      refused =
        ~s(Refused, nothing saved. severity: "high" is not one of blocker, major, minor, nit. ) <>
          ~s(line: must be a whole number, got "88-94". ) <>
          "file: a code finding's Where is the `file` and `line` it is in."

      assert {:error, {:refused, ^refused}} =
               Mcp.call_run_tool(lead, "save_finding", Map.merge(finding, %{"severity" => "high", "line" => "88-94"}))

      assert Pipeline.list_findings(task) == []

      assert {:ok,
              %{
                "content" => [%{"text" => "Saved finding round-query-scope (minor) in round 1 with 1 piece of evidence."}]
              }} =
               Mcp.call_run_tool(lead, "save_finding", finding)

      assert [%Finding{key: "round-query-scope", line: 88}] = Pipeline.list_findings(task)
    end

    test "a field left out is said to be required, and one Rail does not take is ignored", %{lead: lead} do
      assert {:error, {:refused, refused}} =
               Mcp.call_run_tool(lead, "save_finding", %{"key" => "k", "decision" => "skip"})

      assert refused =~ "title: is required."
      assert refused =~ "severity: is required."
      refute refused =~ "decision"
    end

    test "a message no rule spells out is passed on with its values filled in", %{lead: lead, finding: finding} do
      assert {:error, {:refused, "Refused, nothing saved. title: should be at most 90 character(s)."}} =
               Mcp.call_run_tool(lead, "save_finding", Map.put(finding, "title", String.duplicate("t", 91)))
    end

    test "a value of the wrong kind says what kind it wanted", %{lead: lead, finding: finding} do
      assert {:error, {:refused, refused}} =
               Mcp.call_run_tool(
                 lead,
                 "save_finding",
                 Map.merge(finding, %{"title" => 7, "steps" => "open it", "places" => "the list page"})
               )

      assert refused =~ "title: must be text, got 7."
      assert refused =~ ~s(steps: must be a list, got "open it".)
      assert refused =~ ~s(places: must be a list of entries, got "the list page".)
    end

    test "a refusal inside a list names the entry it was in", %{lead: lead, finding: finding} do
      assert {:error, {:refused, "Refused, nothing saved. places 2 file: " <> _rest}} =
               Mcp.call_run_tool(lead, "save_finding", Map.update!(finding, "places", &[hd(&1), %{"label" => "nowhere"}]))
    end

    test "a field that should be a list says so", %{project: project, task: task} do
      {:ok, plan_role} = Roles.get_role(project_id: project.id, stage: :plan)
      plan = %RunContext{os_process: %OsProcess{task_id: task.id}, role: plan_role, user: nil}

      assert {:error, {:refused, refused}} =
               Mcp.call_run_tool(plan, "save_design_option", %{
                 "key" => "k",
                 "title" => "T",
                 "summary" => "S",
                 "good_at" => "fast"
               })

      assert refused =~ ~s(good_at: must be a list, got "fast".)
    end

    test "each stage's save tool reaches its own save", %{project: project, task: task, lead: lead} do
      context = fn stage ->
        {:ok, role} = Roles.get_role(project_id: project.id, stage: stage)
        %RunContext{os_process: %OsProcess{task_id: task.id}, role: role, user: nil}
      end

      assert {:ok, %{"content" => [%{"text" => "Ticket saved: One round." <> _rest}]}} =
               Mcp.call_run_tool(context.(:plan), "save_ticket", %{"title" => "One round", "description" => "Body."})

      assert {:ok, %{"content" => [%{"text" => "Plan saved, written for no design option yet." <> _rest}]}} =
               Mcp.call_run_tool(context.(:plan), "save_plan", %{"plan" => @plan})

      children = [
        %{"title" => "One", "ticket" => "T1.", "plan" => @part},
        %{"title" => "Two", "ticket" => "T2.", "plan" => @part, "builds_on" => [1]}
      ]

      assert {:ok, %{"content" => [%{"text" => "Split saved into 2 children." <> _rest}]}} =
               Mcp.call_run_tool(context.(:plan), "save_split", %{"children" => children})

      assert {:error, {:refused, "Refused, nothing saved. children 2 plan: is required."}} =
               Mcp.call_run_tool(context.(:plan), "save_split", %{
                 "children" => [hd(children), Map.delete(List.last(children), "plan")]
               })

      assert {:ok, %{"content" => [%{"text" => "Write-up saved: One round."}]}} =
               Mcp.call_run_tool(lead, "save_demo", %{"title" => "One round", "summary" => "Shown."})

      # Each is handed the turn that called it, which it ends.
      expect(Pipeline, :end_turn_and_commit, fn _task,
                                                %OsProcess{task_id: task_id},
                                                %{"message" => "CRS-1: the change"} ->
        assert task_id == task.id
        {:ok, :committing}
      end)

      expect(Pipeline, :end_turn_and_merge, fn _task, %OsProcess{} -> {:refused, "Refused, nothing merged."} end)

      assert {:ok, %{"content" => [%{"text" => "Your turn is over." <> _rest}]}} =
               Mcp.call_run_tool(context.(:engineer), "commit", %{"message" => "CRS-1: the change"})

      assert {:error, {:refused, "Refused, nothing merged."}} =
               Mcp.call_run_tool(context.(:engineer), "request_merge", %{})
    end

    # The engineer and the Review lead hand work over through the one `commit`, and only they do.
    test "the Review lead's commit reaches the same commit with the round it describes", %{
      project: project,
      lead: lead,
      run: run,
      task: %{id: task_id}
    } do
      round = %{"message" => "Scope the round query", "findings" => [%{"key" => "round-query-scope"}]}

      expect(Pipeline, :end_turn_and_commit, 2, fn
        %Task{id: ^task_id}, %OsProcess{}, ^round ->
          {:ok, :committing}

        %Task{id: ^task_id}, %OsProcess{}, %{"findings" => []} ->
          {:refused, "Refused, nothing committed. the round leaves out round-query-scope, ruled Fix."}
      end)

      assert {:ok, %{"content" => [%{"text" => "Your turn is over. Rail is committing your work" <> _rest}]}} =
               Mcp.call_run_tool(lead, "commit", round)

      assert {:error, {:refused, "Refused, nothing committed. the round leaves out round-query-scope, ruled Fix."}} =
               Mcp.call_run_tool(lead, "commit", %{round | "findings" => []})

      # A save is not logged: the transcript already shows the call.
      assert Pipeline.list_run_events(run) == []

      {:ok, plan} = Roles.get_role(project_id: project.id, stage: :plan)
      assert {:error, :unknown_tool} = Mcp.call_run_tool(%{lead | role: plan}, "commit", round)
      assert {:error, :unknown_tool} = Mcp.call_run_tool(lead, "commit_fixes", round)
    end

    test "saves and their refusals append nothing to the run's log", %{lead: lead, run: run, task: task} do
      {:ok, _closed} = Mcp.call_run_tool(lead, "save_review", %{})
      {:error, {:refused, _refused}} = Mcp.call_run_tool(lead, "save_finding", %{})

      assert Pipeline.list_run_events(run) == []
      assert [%{round: 1}] = task |> Repo.preload(:issue) |> Pipeline.read_review()
    end
  end

  describe "knowledge_search" do
    setup %{project: project} do
      task = learnings_task(project, "KNS-1")
      {:ok, role} = Roles.get_role(project_id: project.id, stage: :engineer)

      {:ok, run} =
        Pipeline.create_run(%{task_id: task.id, role_id: role.id, status: :running, started_at: DateTime.utc_now()})

      near =
        learning(project, %{rule: "Filters live in the URL", why: "So a view can be linked", kind: :convention},
          embedding: [1.0]
        )

      learning(project, %{rule: "Reviewers only", kind: :calibration, roles: [:review]}, embedding: [1.0])

      context = %RunContext{os_process: %OsProcess{run_id: run.id, task_id: task.id}, role: role}
      %{context: context, run: run, near: near}
    end

    test "a run gets the rules for its project and role, nearest first, and the call is logged", %{
      context: context,
      run: run,
      near: near
    } do
      stub_vertex(%{"filters" => vector([1.0])})

      expected = "- `#{near.id}` Convention: Filters live in the URL\n  Why: So a view can be linked"

      assert {:ok, %{"content" => [%{"type" => "text", "text" => ^expected}]}} =
               Mcp.call_run_tool(context, "knowledge_search", %{"query" => "where do filters go"})

      assert Enum.any?(Pipeline.list_run_events(run), &(&1.line == ~s([knowledge] search "where do filters go")))
    end

    test "a triage pass, which has no task, can search too", %{project: project} do
      stub_vertex(%{"filters" => vector([1.0])})
      {:ok, triage} = Roles.get_role(project_id: project.id, stage: :triage)

      assert {:ok, %{"content" => [%{"text" => "- `lrn_" <> _rest}]}} =
               Mcp.call_run_tool(%RunContext{os_process: nil, role: triage}, "knowledge_search", %{"query" => "filters"})
    end

    test "a missing query, nothing near, or a search that cannot run each answer in a sentence", %{context: context} do
      assert {:ok, %{"content" => [%{"text" => "knowledge_search needs a `query`" <> _rest}]}} =
               Mcp.call_run_tool(context, "knowledge_search", nil)

      assert {:ok, %{"content" => [%{"text" => "knowledge_search needs a `query`" <> _rest}]}} =
               Mcp.call_run_tool(context, "knowledge_search", %{"query" => "  "})

      assert {:ok, %{"content" => [%{"text" => "The knowledge base cannot be searched right now." <> _rest}]}} =
               Mcp.call_run_tool(context, "knowledge_search", %{"query" => "filters"})

      stub_vertex()
      Repo.update_all(Rail.Learnings.Schemas.Learning, set: [embedding: nil])

      assert {:ok, %{"content" => [%{"text" => "No rule this project has learned matches that."}]}} =
               Mcp.call_run_tool(context, "knowledge_search", %{"query" => "filters"})
    end
  end
end
