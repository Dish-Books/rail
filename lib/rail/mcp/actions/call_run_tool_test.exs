defmodule Rail.Mcp.Actions.CallRunToolTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Mcp
  alias Rail.Mcp.RunContext
  alias Rail.Mcp.Schemas.McpConnection
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.ReviewFinding
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Tools.Schemas.OsProcess
  alias Rail.Users

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

      {:ok, role} = Roles.get_role(project_id: project.id, stage: :review)

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

      %{task: task, run: run, review: %RunContext{os_process: os_process, role: role, user: nil}}
    end

    test "a review run calling another stage's save tool is told there is no such tool", %{review: review} do
      assert {:error, :unknown_tool} = Mcp.call_run_tool(review, "save_ticket", %{"title" => "T", "description" => "D"})
    end

    test "a malformed finding is refused naming each field, and the corrected call is saved", %{
      review: review,
      task: task
    } do
      finding = %{"key" => "round-query-scope", "title" => "The round reads other tasks", "recommendation" => "fix"}

      refused =
        ~s(Refused, nothing saved. severity: "high" is not one of blocker, major, minor, nit. ) <>
          ~s(line: must be a whole number, got "88-94".)

      assert {:error, {:refused, ^refused}} =
               Mcp.call_run_tool(review, "save_finding", Map.merge(finding, %{"severity" => "high", "line" => "88-94"}))

      assert Pipeline.list_review_findings(task) == []

      assert {:ok, %{"content" => [%{"text" => "Saved finding round-query-scope (minor)."}]}} =
               Mcp.call_run_tool(review, "save_finding", Map.merge(finding, %{"severity" => "minor", "line" => 88}))

      assert [%ReviewFinding{key: "round-query-scope", line: 88}] = Pipeline.list_review_findings(task)
    end

    test "a field left out is said to be required, and one Rail does not take is ignored", %{review: review} do
      assert {:error, {:refused, refused}} =
               Mcp.call_run_tool(review, "save_finding", %{"key" => "k", "decision" => "skip"})

      assert refused =~ "title: is required."
      assert refused =~ "severity: is required."
      refute refused =~ "decision"
    end

    test "a message no rule spells out is passed on with its values filled in", %{review: review} do
      assert {:error, {:refused, "Refused, nothing saved. line: must be a positive whole number."}} =
               Mcp.call_run_tool(review, "save_finding", %{
                 "key" => "k",
                 "title" => "T",
                 "severity" => "minor",
                 "recommendation" => "fix",
                 "line" => 0
               })
    end

    test "a value of the wrong kind says what kind it wanted", %{project: project, task: task} do
      {:ok, qa_role} = Roles.get_role(project_id: project.id, stage: :qa)
      qa = %RunContext{os_process: %OsProcess{task_id: task.id}, role: qa_role, user: nil}

      assert {:error, {:refused, refused}} =
               Mcp.call_run_tool(qa, "save_finding", %{
                 "key" => "k",
                 "title" => 7,
                 "check" => "c",
                 "severity" => "minor",
                 "recommendation" => "fix",
                 "caused_by_change" => "maybe",
                 "evidence" => "a picture"
               })

      assert refused =~ "title: must be text, got 7."
      assert refused =~ ~s(caused_by_change: must be true or false, got "maybe".)
      assert refused =~ ~s(evidence: must be a list of entries, got "a picture".)
    end

    test "a refusal inside a list names the entry it was in", %{project: project, task: task} do
      {:ok, design_role} = Roles.get_role(project_id: project.id, stage: :design)
      design = %RunContext{os_process: %OsProcess{task_id: task.id}, role: design_role, user: nil}

      assert {:error, {:refused, refused}} =
               Mcp.call_run_tool(design, "save_design_option", %{
                 "key" => "k",
                 "title" => "T",
                 "summary" => "S",
                 "good_at" => "fast"
               })

      assert refused =~ ~s(good_at: must be a list, got "fast".)
    end

    test "each stage's save tool reaches its own save", %{project: project, task: task} do
      context = fn stage ->
        {:ok, role} = Roles.get_role(project_id: project.id, stage: stage)
        %RunContext{os_process: %OsProcess{task_id: task.id}, role: role, user: nil}
      end

      assert {:ok, %{"content" => [%{"text" => "Ticket saved: One round." <> _rest}]}} =
               Mcp.call_run_tool(context.(:product), "save_ticket", %{"title" => "One round", "description" => "Body."})

      assert {:ok, %{"content" => [%{"text" => "Plan saved." <> _rest}]}} =
               Mcp.call_run_tool(context.(:architect), "save_plan", %{"plan" => "## Implementation plan\n\nDo it."})

      assert {:ok, %{"content" => [%{"text" => "Verdict saved: Passed." <> _rest}]}} =
               Mcp.call_run_tool(context.(:qa), "save_verdict", %{"verdict" => "pass", "summary" => "Works."})

      assert {:ok, %{"content" => [%{"text" => "Write-up saved: One round."}]}} =
               Mcp.call_run_tool(context.(:demo), "save_demo", %{"title" => "One round", "summary" => "Shown."})

      expect(Pipeline, :end_turn_and_commit, fn _task, "CRS-1: the change" -> {:ok, :committing} end)
      expect(Pipeline, :end_turn_and_merge, fn _task -> {:refused, "Refused, nothing merged."} end)

      assert {:ok, %{"content" => [%{"text" => "Your turn is over." <> _rest}]}} =
               Mcp.call_run_tool(context.(:engineer), "commit", %{"message" => "CRS-1: the change"})

      assert {:error, {:refused, "Refused, nothing merged."}} =
               Mcp.call_run_tool(context.(:engineer), "request_merge", %{})
    end

    test "saves and their refusals append nothing to the run's log", %{review: review, run: run, task: task} do
      {:ok, _closed} = Mcp.call_run_tool(review, "save_review", %{})
      {:error, {:refused, _refused}} = Mcp.call_run_tool(review, "save_finding", %{})

      assert Pipeline.list_run_events(run) == []
      assert %DateTime{} = task |> Repo.preload(:issue) |> Pipeline.read_review()
    end
  end
end
