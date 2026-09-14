defmodule Rail.Mcp.Actions.ListRunToolsTest do
  use Rail.DataCase, async: true

  alias Rail.Mcp
  alias Rail.Mcp.RunContext
  alias Rail.Mcp.Schemas.McpConnection
  alias Rail.Roles.Schemas.Role
  alias Rail.Users

  setup do
    id = System.unique_integer([:positive])

    {:ok, user} =
      Users.register_oauth_user(%{github_id: "lrt_gh_#{id}", login: "lrt_#{id}", email: "lrt_#{id}@example.com"})

    {:ok, linear} =
      Mcp.create_server(system_scope(), %{
        name: "lrt_linear",
        url: "https://linear.example.com/mcp",
        token_endpoint: "https://auth.example.com/token",
        client_id: "client_1"
      })

    Repo.insert!(%McpConnection{
      user_id: user.id,
      mcp_server_id: linear.id,
      access_token: "at_linear",
      expires_at: DateTime.shift(DateTime.utc_now(), hour: 1)
    })

    {:ok, _open} =
      Mcp.create_server(system_scope(), %{
        name: "lrt_open",
        url: "https://open.example.com/mcp",
        auth: :none
      })

    {:ok, _sentry} =
      Mcp.create_server(system_scope(), %{name: "lrt_sentry", url: "https://sentry.example.com/mcp"})

    {:ok, _off} =
      Mcp.create_server(system_scope(), %{
        name: "lrt_off",
        url: "https://off.example.com/mcp",
        auth: :none,
        enabled: false
      })

    {:ok, _broken} =
      Mcp.create_server(system_scope(), %{
        name: "lrt_broken",
        url: "https://broken.example.com/mcp",
        auth: :none
      })

    Req.Test.stub(Mcp, fn conn ->
      case {conn.host, conn |> Req.Test.raw_body() |> Jason.decode!()} do
        {"broken.example.com", _message} ->
          Plug.Conn.send_resp(conn, 500, "down")

        {_host, %{"method" => "notifications/initialized"}} ->
          Plug.Conn.send_resp(conn, 202, "")

        {_host, %{"method" => "initialize", "id" => id}} ->
          Req.Test.json(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => %{}})

        {"linear.example.com", %{"method" => "tools/list", "id" => id}} ->
          assert ["Bearer at_linear"] = Plug.Conn.get_req_header(conn, "authorization")

          Req.Test.json(conn, %{
            "jsonrpc" => "2.0",
            "id" => id,
            "result" => %{"tools" => [%{"name" => "get_issue"}, %{"name" => "delete_issue"}]}
          })

        {"open.example.com", %{"method" => "tools/list", "id" => id}} ->
          Req.Test.json(conn, %{
            "jsonrpc" => "2.0",
            "id" => id,
            "result" => %{"tools" => [%{"name" => "a", "inputSchema" => %{}}, %{"name" => "b"}]}
          })
      end
    end)

    %{user: user}
  end

  test "lists allowed tools on reachable servers, prefixed by server name", %{user: user} do
    context = %RunContext{
      role: %Role{mcp_tools: ["lrt_linear__get_issue", "lrt_open__*", "lrt_sentry__*", "lrt_off__*", "lrt_broken__*"]},
      user: user
    }

    assert {:ok,
            [
              %{"name" => "lrt_linear__get_issue"},
              %{"name" => "lrt_open__a", "inputSchema" => %{}},
              %{"name" => "lrt_open__b"}
            ]} =
             Mcp.list_run_tools(context)
  end

  test "an unassigned issue only reaches servers that need no account" do
    context = %RunContext{role: %Role{mcp_tools: ["lrt_linear__*", "lrt_open__b"]}, user: nil}

    assert {:ok, [%{"name" => "lrt_open__b"}]} = Mcp.list_run_tools(context)
  end

  test "a role without MCP tools lists none" do
    assert {:ok, []} = Mcp.list_run_tools(%RunContext{role: %Role{mcp_tools: []}, user: nil})
  end
end
