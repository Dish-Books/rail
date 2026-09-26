defmodule RailWeb.Settings.SlackWorkspacesLiveTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Projects
  alias Rail.Projects.Schemas.SlackWorkspace
  alias Rail.Repo
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
end
