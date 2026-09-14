defmodule RailWeb.Settings.McpServersLiveTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Mcp
  alias Rail.Mcp.Schemas.McpServer
  alias Rail.Users

  setup %{conn: conn} do
    id = System.unique_integer([:positive])

    {:ok, admin} =
      Users.register_oauth_user(%{
        github_id: "msl_admin_gh_#{id}",
        login: "msl_admin_#{id}",
        email: "msl_admin_#{id}@example.com",
        admin: true
      })

    {:ok, regular} =
      Users.register_oauth_user(%{github_id: "msl_gh_#{id}", login: "msl_#{id}", email: "msl_#{id}@example.com"})

    %{admin_conn: log_in_user(conn, admin), regular_conn: log_in_user(conn, regular)}
  end

  test "is admin only", %{regular_conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/settings/mcp-servers")
  end

  test "adds a server from the modal and discovers it", %{admin_conn: conn} do
    assert {:ok, view, _html} = live(conn, ~p"/settings/mcp-servers")
    assert has_element?(view, "#mcp-servers-empty")
    assert has_element?(view, "#tab-mcp-servers")
    refute has_element?(view, "#mcp-server-modal")

    view |> element("#new-server-button") |> render_click()
    assert has_element?(view, "#mcp-server-modal")

    view |> element("#cancel-server-button") |> render_click()
    refute has_element?(view, "#mcp-server-modal")

    view |> element("#new-server-button") |> render_click()
    view |> element("#mcp-server-form") |> render_change(%{"server" => %{"name" => "msl", "url" => ""}})
    view |> element("#mcp-server-form") |> render_submit(%{"server" => %{"name" => "Bad!", "url" => "x"}})

    assert has_element?(view, "#mcp-server-name-error")
    assert has_element?(view, "#mcp-server-url-error")

    Req.Test.expect(Mcp, &Req.Test.json(&1, %{"jsonrpc" => "2.0", "id" => 0, "result" => %{}}))

    html =
      view
      |> element("#mcp-server-form")
      |> render_submit(%{"server" => %{"name" => " msl_open ", "url" => "https://open.example.com/mcp"}})

    assert html =~ "msl_open: No auth."
    refute has_element?(view, "#mcp-server-modal")
    assert has_element?(view, "#mcp-server-status-msl_open", "No auth")

    view |> element("#new-server-button") |> render_click()
    view |> element("#close-modal-button") |> render_click()
    refute has_element?(view, "#mcp-server-modal")
  end

  test "reports discovery failures", %{admin_conn: conn} do
    {:ok, %McpServer{id: server_id}} =
      Mcp.create_server(system_scope(), %{name: "msl_linear", url: "https://mcp.example.com/mcp"})

    assert {:ok, view, _html} = live(conn, ~p"/settings/mcp-servers")
    assert has_element?(view, "#mcp-server-status-msl_linear", "Not discovered")

    stub_errors = [
      {:no_registration_endpoint, "does not support dynamic client registration"},
      {:authorization_server_not_found, "no OAuth authorization server metadata"},
      {:not_connected, "connect your own account first"},
      {%Req.TransportError{reason: :econnrefused}, "could not reach the server (:econnrefused)"},
      {{:mcp_http_error, 500, "down"}, "mcp_http_error"}
    ]

    for {reason, message} <- stub_errors do
      expect(Mcp, :discover_server, fn _scope, %McpServer{id: ^server_id} -> {:error, reason} end)
      assert view |> element("#discover-msl_linear") |> render_click() =~ message
    end
  end

  test "refreshes tools, toggles and deletes servers", %{admin_conn: conn} do
    {:ok, _server} =
      Mcp.create_server(system_scope(), %{name: "msl_open", url: "https://open.example.com/mcp", auth: :none})

    {:ok, _server} =
      Mcp.create_server(system_scope(), %{name: "msl_linear", url: "https://mcp.example.com/mcp", client_id: "client_1"})

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
            "result" => %{"tools" => [%{"name" => "a"}, %{"name" => "b"}]}
          })
      end
    end)

    assert {:ok, view, _html} = live(conn, ~p"/settings/mcp-servers")
    assert has_element?(view, "#mcp-server-status-msl_linear", "OAuth ready")

    assert view |> element("#refresh-tools-msl_open") |> render_click() =~ "msl_open: 2 tools."
    assert has_element?(view, "#mcp-server-tools-msl_open", "2")

    assert view |> element("#refresh-tools-msl_linear") |> render_click() =~ "connect your own account first"

    view |> element("#toggle-msl_open") |> render_click()
    assert has_element?(view, "#toggle-msl_open", "Enable")
    assert has_element?(view, "#mcp-server-disabled-msl_open")

    view |> element("#delete-msl_open") |> render_click()
    refute has_element?(view, "#mcp-server-msl_open")

    render_click(view, "discover", %{"id" => "mcs_missing"})
    send(view.pid, :pipeline_event)
    assert has_element?(view, "#mcp-server-msl_linear")
  end
end
