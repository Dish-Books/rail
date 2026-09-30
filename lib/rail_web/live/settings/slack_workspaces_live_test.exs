defmodule RailWeb.Settings.SlackWorkspacesLiveTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Projects
  alias Rail.Projects.Schemas.SlackWorkspace
  alias Rail.Repo
  alias Rail.Triage.SlackSocket
  alias Rail.Users

  setup %{conn: conn} do
    id = System.unique_integer([:positive])

    {:ok, admin} =
      Users.register_oauth_user(%{github_id: "sw_a_#{id}", login: "sw_a_#{id}", email: "sw_a_#{id}@x.com", admin: true})

    {:ok, regular} =
      Users.register_oauth_user(%{github_id: "sw_u_#{id}", login: "sw_u_#{id}", email: "sw_u_#{id}@x.com"})

    %{admin_conn: log_in_user(conn, admin), regular_conn: log_in_user(conn, regular), team_id: "T#{id}"}
  end

  test "redirects a non-admin to /", %{regular_conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/settings/slack-workspaces")
  end

  test "an admin adds a workspace, with what the Slack app needs spelled out", %{admin_conn: conn, team_id: team_id} do
    assert {:ok, view, _html} = live(conn, ~p"/settings/slack-workspaces")
    assert has_element?(view, "#tab-slack-workspaces")
    assert has_element?(view, "#empty-slack-workspaces-message")
    assert has_element?(view, "#slack-setup-note", "connections:write")

    view |> element("#new-slack-workspace-button") |> render_click()
    view |> form("#slack-workspace-form", %{"slack_workspace" => %{"name" => "Acme"}}) |> render_change()
    assert render(view) =~ "can&#39;t be blank"

    # Typed tokens survive the re-render that typing in the other field causes.
    view
    |> form("#slack-workspace-form", %{"slack_workspace" => %{"name" => "Acme", "token" => "xoxb-acme"}})
    |> render_change()

    view
    |> form("#slack-workspace-form", %{
      "slack_workspace" => %{"name" => "Acme", "token" => "xoxb-acme", "app_token" => "xapp-acme"}
    })
    |> render_change()

    assert has_element?(view, "#slack-workspace-token-input[value='xoxb-acme']")
    assert has_element?(view, "#slack-workspace-app-token-input[value='xapp-acme']")

    Req.Test.expect(Rail.Slack, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer xoxb-acme"]
      Req.Test.json(conn, %{"ok" => true, "team_id" => team_id, "bot_id" => "B1"})
    end)

    view
    |> form("#slack-workspace-form", %{
      "slack_workspace" => %{"name" => "Acme", "token" => "xoxb-acme", "app_token" => "xapp-acme"}
    })
    |> render_submit()

    refute has_element?(view, "#slack-workspace-modal")
    assert %SlackWorkspace{id: id, app_token: "xapp-acme"} = Repo.get_by!(SlackWorkspace, external_id: team_id)
    assert has_element?(view, "#slack-workspace-item-#{id}", team_id)
  end

  test "a token Slack refuses keeps the form open with why", %{admin_conn: conn} do
    assert {:ok, view, _html} = live(conn, ~p"/settings/slack-workspaces")
    view |> element("#new-slack-workspace-button") |> render_click()

    Req.Test.expect(Rail.Slack, &Req.Test.json(&1, %{"ok" => false, "error" => "invalid_auth"}))

    view
    |> form("#slack-workspace-form", %{"slack_workspace" => %{"name" => "Acme", "token" => "xoxb-bad"}})
    |> render_submit()

    assert has_element?(view, "#slack-workspace-modal", "was refused by Slack (invalid_auth)")
  end

  test "edits a workspace, and blank tokens keep the saved ones", %{admin_conn: conn, team_id: team_id} do
    Req.Test.expect(Rail.Slack, &Req.Test.json(&1, %{"ok" => true, "team_id" => team_id}))

    {:ok, workspace} =
      Projects.create_slack_workspace(system_scope(), %{"name" => "Before", "token" => "xoxb-1", "app_token" => "xapp-1"})

    assert {:ok, view, _html} = live(conn, ~p"/settings/slack-workspaces")
    view |> element("#edit-slack-workspace-#{workspace.id}") |> render_click()
    assert has_element?(view, "#modal-title", "Edit Slack Workspace")

    # Only what was typed here is echoed back; the saved tokens never reach the page.
    view |> form("#slack-workspace-form", %{"slack_workspace" => %{"name" => "After"}}) |> render_change()
    refute render(view) =~ "xoxb-1"
    refute render(view) =~ "xapp-1"

    view
    |> form("#slack-workspace-form", %{"slack_workspace" => %{"name" => "After", "token" => "", "app_token" => ""}})
    |> render_submit()

    assert %SlackWorkspace{name: "After", token: "xoxb-1", app_token: "xapp-1"} = Repo.get!(SlackWorkspace, workspace.id)

    view |> element("#edit-slack-workspace-#{workspace.id}") |> render_click()
    view |> element("#close-modal-button") |> render_click()
    refute has_element?(view, "#slack-workspace-modal")

    render_hook(view, "edit_workspace", %{"id" => "sw_missing"})
    refute has_element?(view, "#slack-workspace-modal")
  end

  test "each row says whether its Socket Mode connection is up, and why not", %{admin_conn: conn, team_id: team_id} do
    %{url: url} = Rail.FakeSlack.fake_slack(self())

    Req.Test.stub(Rail.Slack, fn conn ->
      case conn.request_path do
        "/api/auth.test" -> Req.Test.json(conn, %{"ok" => true, "team_id" => "#{team_id}#{System.unique_integer()}"})
        "/api/apps.connections.open" -> Req.Test.json(conn, %{"ok" => true, "url" => url})
      end
    end)

    {:ok, up} = Projects.create_slack_workspace(system_scope(), %{"name" => "Up", "token" => "x", "app_token" => "xapp"})

    {:ok, idle} =
      Projects.create_slack_workspace(system_scope(), %{"name" => "Idle", "token" => "x", "app_token" => "xapp"})

    {:ok, bare} = Projects.create_slack_workspace(system_scope(), %{"name" => "Bare", "token" => "x"})

    start_supervised!({SlackSocket, workspace: up, backoff: 10})
    assert_receive {:fake_slack_connected, _socket}, 5_000
    eventually(fn -> assert :connected = Rail.Triage.get_slack_socket_status(up) end)

    assert {:ok, view, _html} = live(conn, ~p"/settings/slack-workspaces")
    assert has_element?(view, "#slack-socket-status-#{up.id}", "Socket Mode: connected")
    assert has_element?(view, "#slack-socket-status-#{idle.id}", "Socket Mode: not running")
    assert has_element?(view, "#slack-socket-status-#{bare.id}", "Socket Mode: no app-level token")
  end

  test "a row says why Slack refuses its socket", %{admin_conn: conn, team_id: team_id} do
    Req.Test.stub(Rail.Slack, fn conn ->
      case conn.request_path do
        "/api/auth.test" -> Req.Test.json(conn, %{"ok" => true, "team_id" => team_id})
        "/api/apps.connections.open" -> Req.Test.json(conn, %{"ok" => false, "error" => "not_allowed_token_type"})
      end
    end)

    {:ok, down} = Projects.create_slack_workspace(system_scope(), %{"name" => "Down", "token" => "x", "app_token" => "x"})
    start_supervised!({SlackSocket, workspace: down, backoff: 10})
    eventually(fn -> assert {:error, _reason} = Rail.Triage.get_slack_socket_status(down) end)

    assert {:ok, view, _html} = live(conn, ~p"/settings/slack-workspaces")
    assert has_element?(view, "#slack-socket-status-#{down.id}", "Socket Mode: failing (not_allowed_token_type)")
  end

  test "a row says when its socket is still connecting, or cannot reach Slack", %{admin_conn: conn, team_id: team_id} do
    test = self()

    Req.Test.stub(Rail.Slack, fn conn ->
      case conn.request_path do
        "/api/auth.test" ->
          Req.Test.json(conn, %{"ok" => true, "team_id" => "#{team_id}#{System.unique_integer()}"})

        "/api/apps.connections.open" ->
          send(test, {:opening, self()})

          receive do
            :fail -> Req.Test.transport_error(conn, :econnrefused)
          end
      end
    end)

    {:ok, slow} = Projects.create_slack_workspace(system_scope(), %{"name" => "Slow", "token" => "x", "app_token" => "x"})
    start_supervised!({SlackSocket, workspace: slow, backoff: 60_000})
    assert_receive {:opening, socket}, 5_000

    assert {:ok, view, _html} = live(conn, ~p"/settings/slack-workspaces")
    assert has_element?(view, "#slack-socket-status-#{slow.id}", "Socket Mode: connecting")

    send(socket, :fail)
    eventually(fn -> assert {:error, _reason} = Rail.Triage.get_slack_socket_status(slow) end)

    assert {:ok, view, _html} = live(conn, ~p"/settings/slack-workspaces")
    assert has_element?(view, "#slack-socket-status-#{slow.id}", "Socket Mode: failing (")
  end
end
