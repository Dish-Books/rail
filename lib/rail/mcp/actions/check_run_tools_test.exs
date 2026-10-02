defmodule Rail.Mcp.Actions.CheckRunToolsTest do
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

    {:ok, _open} =
      Mcp.create_server(system_scope(), %{name: "crt_open", url: "https://open.example.com/mcp", auth: :none})

    {:ok, _off} =
      Mcp.create_server(system_scope(), %{name: "crt_off", url: "https://off.example.com/mcp", enabled: false})

    connection =
      Repo.insert!(%McpConnection{
        user_id: user.id,
        mcp_server_id: linear.id,
        access_token: "at_linear",
        refresh_token: "rt_linear",
        expires_at: DateTime.shift(DateTime.utc_now(), hour: 1)
      })

    Req.Test.stub(Mcp, fn conn ->
      case conn |> Req.Test.raw_body() |> Jason.decode!() do
        %{"method" => "notifications/initialized"} -> Plug.Conn.send_resp(conn, 202, "")
        %{"method" => "initialize", "id" => id} -> Req.Test.json(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => %{}})
        %{"method" => "tools/list", "id" => id} -> Req.Test.json(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => %{}})
      end
    end)

    %{user: user, connection: connection}
  end

  test "every server the role names answers on the user's connection", %{user: user} do
    role = %Role{mcp_tools: ["crt_linear__list_issues", "crt_open__*", "crt_off__*", "crt_gone__*"]}

    assert :ok = Mcp.check_run_tools(%RunContext{role: role, user: user})
    assert :ok = Mcp.check_run_tools(%RunContext{role: %Role{mcp_tools: []}, user: nil})
    assert :ok = Mcp.check_run_tools(%RunContext{role: %Role{mcp_tools: ["crt_open__*"]}, user: nil})
  end

  test "a server the user never connected, or with nobody to connect it, needs reconnecting", %{
    user: user,
    connection: connection
  } do
    role = %Role{mcp_tools: ["crt_linear__*", "crt_open__*"]}

    assert {:error, {:mcp_reconnect, ["crt_linear"]}} = Mcp.check_run_tools(%RunContext{role: role, user: nil})

    Repo.delete!(connection)
    assert {:error, {:mcp_reconnect, ["crt_linear"]}} = Mcp.check_run_tools(%RunContext{role: role, user: user})
  end

  test "a token the server rejects and the token endpoint will not refresh needs reconnecting", %{user: user} do
    Req.Test.stub(Mcp, fn
      %{host: "auth.example.com"} = conn ->
        conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "invalid_grant"})

      conn ->
        Plug.Conn.send_resp(conn, 401, "")
    end)

    assert {:error, {:mcp_reconnect, ["crt_linear"]}} =
             Mcp.check_run_tools(%RunContext{role: %Role{mcp_tools: ["crt_linear__*"]}, user: user})
  end

  test "a server that is down is unreachable, and reconnecting is asked first", %{user: user, connection: connection} do
    Req.Test.stub(Mcp, &Plug.Conn.send_resp(&1, 500, "down"))
    role = %Role{mcp_tools: ["crt_linear__*", "crt_open__*"]}

    assert {:error, {:mcp_unreachable, ["crt_linear", "crt_open"]}} =
             Mcp.check_run_tools(%RunContext{role: role, user: user})

    Repo.delete!(connection)
    assert {:error, {:mcp_reconnect, ["crt_linear"]}} = Mcp.check_run_tools(%RunContext{role: role, user: user})
  end
end
