defmodule RailWeb.Settings.LinearWorkspacesLiveTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Projects
  alias Rail.Projects.Schemas.LinearWorkspace
  alias Rail.Repo
  alias Rail.Users

  setup %{conn: conn} do
    id = System.unique_integer([:positive])

    {:ok, admin} =
      Users.register_oauth_user(%{
        github_id: "ws_admin_#{id}",
        login: "ws_admin_#{id}",
        email: "ws_admin_#{id}@example.com",
        admin: true
      })

    {:ok, regular} =
      Users.register_oauth_user(%{
        github_id: "ws_user_#{id}",
        login: "ws_user_#{id}",
        email: "ws_user_#{id}@example.com",
        admin: false
      })

    %{admin_conn: log_in_user(conn, admin), regular_conn: log_in_user(conn, regular)}
  end

  test "redirects a non-admin to /", %{regular_conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/settings/linear-workspaces")
  end

  test "lists each workspace with the projects on it", %{admin_conn: conn, project: project} do
    assert {:ok, view, _html} = live(conn, ~p"/settings/linear-workspaces")

    assert has_element?(view, "#tab-linear-workspaces")
    assert has_element?(view, "#workspace-item-#{project.linear_workspace_id}", "lin_org_test_seed")
    assert has_element?(view, "#workspace-projects-#{project.linear_workspace_id}", "Test Project")

    # The navigation hook's pipeline events change nothing here.
    send(view.pid, {:issue_created, "iss_any"})
    assert has_element?(view, "#workspace-item-#{project.linear_workspace_id}")
  end

  test "creates a workspace, showing what is missing first", %{admin_conn: conn} do
    assert {:ok, view, _html} = live(conn, ~p"/settings/linear-workspaces")
    view |> element("#new-workspace-button") |> render_click()

    refute render(view) =~ "can&#39;t be blank"

    view |> form("#workspace-form", %{"linear_workspace" => %{"name" => "Acme"}}) |> render_change()
    assert render(view) =~ "can&#39;t be blank"

    view
    |> form("#workspace-form", %{
      "linear_workspace" => %{
        "name" => "Acme",
        "external_id" => "lin_org_acme",
        "token" => "lin_api_acme",
        "webhook_secret" => "whsec_acme"
      }
    })
    |> render_submit()

    refute has_element?(view, "#workspace-modal")
    assert %LinearWorkspace{id: id, token: "lin_api_acme"} = Repo.get_by!(LinearWorkspace, external_id: "lin_org_acme")
    assert has_element?(view, "#workspace-projects-#{id}", "none")
  end

  test "an invalid save keeps the form open with its errors", %{admin_conn: conn} do
    assert {:ok, view, _html} = live(conn, ~p"/settings/linear-workspaces")
    view |> element("#new-workspace-button") |> render_click()

    view |> form("#workspace-form", %{"linear_workspace" => %{"name" => "Only a name"}}) |> render_submit()

    assert has_element?(view, "#workspace-modal")
    assert render(view) =~ "can&#39;t be blank"
  end

  test "edits a workspace, and blank secrets keep the saved ones", %{admin_conn: conn} do
    {:ok, workspace} =
      Projects.create_linear_workspace(system_scope(), %{
        name: "Before",
        external_id: "lin_org_edit",
        token: "lin_api_edit",
        webhook_secret: "whsec_edit"
      })

    assert {:ok, view, _html} = live(conn, ~p"/settings/linear-workspaces")
    view |> element("#edit-workspace-#{workspace.id}") |> render_click()

    assert has_element?(view, "#modal-title", "Edit Linear Workspace")
    assert has_element?(view, "#workspace-token-input[value='']")

    view
    |> form("#workspace-form", %{"linear_workspace" => %{"name" => "After", "token" => "", "webhook_secret" => ""}})
    |> render_submit()

    assert %LinearWorkspace{name: "After", token: "lin_api_edit", webhook_secret: "whsec_edit"} =
             Repo.get!(LinearWorkspace, workspace.id)
  end

  test "closing the form and editing one that is gone change nothing", %{admin_conn: conn} do
    assert {:ok, view, _html} = live(conn, ~p"/settings/linear-workspaces")

    view |> element("#new-workspace-button") |> render_click()
    view |> element("#close-modal-button") |> render_click()
    refute has_element?(view, "#workspace-modal")

    render_hook(view, "edit_workspace", %{"id" => "lw_missing"})
    refute has_element?(view, "#workspace-modal")
  end
end
