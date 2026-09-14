defmodule Rail.Mcp.Actions.RefreshServerToolsTest do
  use Rail.DataCase, async: true

  alias Rail.Mcp
  alias Rail.Mcp.Schemas.McpServer
  alias Rail.Scope
  alias Rail.Users

  setup do
    id = System.unique_integer([:positive])

    {:ok, admin} =
      Users.register_oauth_user(%{
        github_id: "rst_gh_#{id}",
        login: "rst_#{id}",
        email: "rst_#{id}@example.com",
        admin: true
      })

    %{scope: Scope.for_user(admin)}
  end

  test "caches each tool's name and description", %{scope: scope} do
    {:ok, server} =
      Mcp.create_server(system_scope(), %{
        name: "rst_open",
        url: "https://open.example.com/mcp",
        auth: :none
      })

    Req.Test.stub(Mcp, fn conn ->
      case conn |> Req.Test.raw_body() |> Jason.decode!() do
        %{"method" => "notifications/initialized"} ->
          Plug.Conn.send_resp(conn, 202, "")

        %{"method" => "initialize", "id" => id} ->
          Req.Test.json(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => %{}})

        %{"method" => "tools/list", "id" => id} ->
          Req.Test.json(conn, %{
            "jsonrpc" => "2.0",
            "id" => id,
            "result" => %{"tools" => [%{"name" => "echo", "description" => "Echoes", "inputSchema" => %{}}]}
          })
      end
    end)

    assert {:ok,
            %McpServer{tools: [%{"name" => "echo", "description" => "Echoes"} = tool], tools_refreshed_at: %DateTime{}}} =
             Mcp.refresh_server_tools(scope, server)

    refute Map.has_key?(tool, "inputSchema")
  end

  test "needs the admin's own connection to an OAuth server", %{scope: scope} do
    {:ok, server} =
      Mcp.create_server(system_scope(), %{name: "rst_linear", url: "https://mcp.linear.app/mcp"})

    assert {:error, :not_connected} = Mcp.refresh_server_tools(scope, server)
    assert {:error, :not_authorized} = Mcp.refresh_server_tools(user_scope(), server)
  end
end
