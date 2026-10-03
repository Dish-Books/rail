defmodule Rail.Mcp.Actions.CallRunToolTest do
  use Rail.DataCase, async: true

  alias Rail.Mcp
  alias Rail.Mcp.RunContext
  alias Rail.Mcp.Schemas.McpConnection
  alias Rail.Roles.Schemas.Role
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
    assert {:ok, %Role{mcp_tools: []} = triage} = Rail.Roles.get_role(project_id: project.id, stage: :triage)
    assert {:error, :unknown_tool} = Mcp.call_run_tool(%RunContext{role: triage, user: user}, "crt_open__echo", %{})

    {:ok, allowed} = Rail.Roles.update_role(system_scope(), triage, %{mcp_tools: ["crt_linear__get_issue"]})
    context = %RunContext{os_process: nil, role: allowed, user: user}
    expected = Jason.encode!(%{"name" => "get_issue", "arguments" => %{"id" => "RAIL-1"}})

    assert {:ok, %{"content" => [%{"text" => ^expected}]}} =
             Mcp.call_run_tool(context, "crt_linear__get_issue", %{"id" => "RAIL-1"})

    assert {:error, :unknown_tool} = Mcp.call_run_tool(context, "crt_open__echo", %{})
  end

  describe "knowledge_search" do
    setup %{project: project} do
      task = learnings_task(project, "KNS-1")
      {:ok, role} = Rail.Roles.get_role(project_id: project.id, stage: :engineer)

      {:ok, run} =
        Rail.Pipeline.create_run(%{task_id: task.id, role_id: role.id, status: :running, started_at: DateTime.utc_now()})

      near =
        learning(project, %{rule: "Filters live in the URL", why: "So a view can be linked", kind: :convention},
          embedding: [1.0]
        )

      learning(project, %{rule: "Reviewers only", kind: :calibration, roles: [:review]}, embedding: [1.0])

      context = %RunContext{os_process: %Rail.Tools.Schemas.OsProcess{run_id: run.id, task_id: task.id}, role: role}
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

      assert Enum.any?(Rail.Pipeline.list_run_events(run), &(&1.line == ~s([knowledge] search "where do filters go")))
    end

    test "a triage pass, which has no task, can search too", %{project: project} do
      stub_vertex(%{"filters" => vector([1.0])})
      {:ok, triage} = Rail.Roles.get_role(project_id: project.id, stage: :triage)

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
