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
end
