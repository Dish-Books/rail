defmodule RailWeb.Settings.IntercomWorkspacesLiveTest do
  use RailWeb.ConnCase, async: true
  use Oban.Testing, repo: Rail.Repo

  import Phoenix.LiveViewTest

  alias Rail.Repo
  alias Rail.Support
  alias Rail.Support.Schemas.IntercomWorkspace
  alias Rail.Support.Workers.BackfillIntercomWorkspace
  alias Rail.Users

  setup %{conn: conn} do
    id = System.unique_integer([:positive])

    {:ok, admin} =
      Users.register_oauth_user(%{github_id: "iw_a_#{id}", login: "iw_a_#{id}", email: "iw_a_#{id}@x.com", admin: true})

    {:ok, regular} =
      Users.register_oauth_user(%{github_id: "iw_u_#{id}", login: "iw_u_#{id}", email: "iw_u_#{id}@x.com"})

    %{admin_conn: log_in_user(conn, admin), regular_conn: log_in_user(conn, regular), app_id: "app#{id}"}
  end

  test "redirects a non-admin to /", %{regular_conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/settings/intercom-workspaces")
  end

  test "an admin connects a workspace to a project, with what the Intercom app needs spelled out, and it starts importing",
       %{admin_conn: conn, app_id: app_id, project: %{id: project_id}} do
    {:ok, view, _html} = live(conn, ~p"/settings/intercom-workspaces")
    assert has_element?(view, "#tab-intercom-workspaces")
    assert has_element?(view, "#empty-intercom-workspaces-message")
    assert has_element?(view, "#intercom-setup-note", "/webhooks/intercom")
    assert has_element?(view, "#intercom-setup-note", "conversation.user.replied")
    assert has_element?(view, "#intercom-setup-note", "/auth/intercom/callback")

    view |> element("#new-intercom-workspace-button") |> render_click()
    assert has_element?(view, "#modal-title", "New Intercom Workspace")
    refute has_element?(view, "#intercom-workspace-modal", "can&#39;t be blank")

    params = %{
      "name" => "Dishbooks Support",
      "project_id" => project_id,
      "access_token" => "tok",
      "client_id" => "cid",
      "client_secret" => "sec"
    }

    view |> form("#intercom-workspace-form", %{"intercom_workspace" => params}) |> render_change()
    assert has_element?(view, "#intercom-workspace-project-input option[value='#{project_id}'][selected]")
    assert has_element?(view, "#intercom-workspace-access-token-input[value='tok']")

    Req.Test.expect(Rail.Intercom, fn conn ->
      assert ["Bearer tok"] = Plug.Conn.get_req_header(conn, "authorization")
      Req.Test.json(conn, %{"app" => %{"id_code" => app_id}})
    end)

    view |> form("#intercom-workspace-form", %{"intercom_workspace" => params}) |> render_submit()

    refute has_element?(view, "#intercom-workspace-modal")

    assert %IntercomWorkspace{id: workspace_id, project_id: ^project_id, client_secret: "sec"} =
             Repo.get_by!(IntercomWorkspace, external_id: app_id)

    assert has_element?(view, "#intercom-workspace-item-#{workspace_id}", app_id)
    assert has_element?(view, "#intercom-workspace-item-#{workspace_id}", "Test Project")
    assert_enqueued(worker: BackfillIntercomWorkspace, args: %{"workspace_id" => workspace_id})
  end

  test "a workspace with no project picked says so and saves nothing", %{admin_conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings/intercom-workspaces")
    view |> element("#new-intercom-workspace-button") |> render_click()

    params = %{"name" => "Acme", "project_id" => "", "access_token" => "t", "client_id" => "c", "client_secret" => "s"}
    view |> form("#intercom-workspace-form", %{"intercom_workspace" => params}) |> render_change()
    assert has_element?(view, "#intercom-workspace-modal", "can't be blank")

    view |> form("#intercom-workspace-form", %{"intercom_workspace" => params}) |> render_submit()

    assert has_element?(view, "#intercom-workspace-modal", "Pick a project")
    assert [] = Repo.all(IntercomWorkspace)
  end

  test "a token Intercom refuses keeps the form open with why", %{admin_conn: conn, project: project} do
    {:ok, view, _html} = live(conn, ~p"/settings/intercom-workspaces")
    view |> element("#new-intercom-workspace-button") |> render_click()

    Req.Test.expect(Rail.Intercom, &Plug.Conn.send_resp(&1, 401, "{}"))

    params = %{
      "name" => "Acme",
      "project_id" => project.id,
      "access_token" => "bad",
      "client_id" => "c",
      "client_secret" => "s"
    }

    view |> form("#intercom-workspace-form", %{"intercom_workspace" => params}) |> render_submit()

    assert has_element?(view, "#intercom-workspace-modal", "Intercom did not accept this token")
  end

  test "edits a workspace, keeping blank secrets, and closes by button or Escape", %{
    admin_conn: conn,
    app_id: app_id,
    project: project
  } do
    Req.Test.expect(Rail.Intercom, &Req.Test.json(&1, %{"app" => %{"id_code" => app_id}}))

    {:ok, workspace} =
      Support.create_intercom_workspace(system_scope(), project, %{
        "name" => "Before",
        "access_token" => "tok-1",
        "client_id" => "cid",
        "client_secret" => "sec-1"
      })

    {:ok, view, _html} = live(conn, ~p"/settings/intercom-workspaces")
    view |> element("#edit-intercom-workspace-#{workspace.id}") |> render_click()
    assert has_element?(view, "#modal-title", "Edit Intercom Workspace")
    refute has_element?(view, "#intercom-workspace-project-input")
    refute render(view) =~ "tok-1"

    view
    |> form("#intercom-workspace-form", %{
      "intercom_workspace" => %{"name" => "After", "access_token" => "", "client_id" => "cid2", "client_secret" => ""}
    })
    |> render_submit()

    assert %IntercomWorkspace{name: "After", client_id: "cid2", access_token: "tok-1", client_secret: "sec-1"} =
             Repo.get!(IntercomWorkspace, workspace.id)

    view |> element("#edit-intercom-workspace-#{workspace.id}") |> render_click()

    view
    |> form("#intercom-workspace-form", %{"intercom_workspace" => %{"name" => "Typing"}})
    |> render_change()

    view |> element("#close-modal-button") |> render_click()
    refute has_element?(view, "#intercom-workspace-modal")

    view |> element("#edit-intercom-workspace-#{workspace.id}") |> render_click()
    view |> element("#intercom-workspace-modal") |> render_keydown(%{"key" => "Escape"})
    refute has_element?(view, "#intercom-workspace-modal")

    render_hook(view, "edit_workspace", %{"id" => "iw_missing"})
    refute has_element?(view, "#intercom-workspace-modal")
  end

  test "a workspace saved in another tab shows, and other messages change nothing", %{
    admin_conn: conn,
    app_id: app_id,
    project: project
  } do
    {:ok, view, _html} = live(conn, ~p"/settings/intercom-workspaces")
    send(view.pid, {:something_else, 1})

    Req.Test.expect(Rail.Intercom, &Req.Test.json(&1, %{"app" => %{"id_code" => app_id}}))

    {:ok, workspace} =
      Support.create_intercom_workspace(system_scope(), project, %{
        "name" => "Elsewhere",
        "access_token" => "t",
        "client_id" => "c",
        "client_secret" => "s"
      })

    send(view.pid, {:intercom_workspace_changed, workspace.id})
    assert has_element?(view, "#intercom-workspace-item-#{workspace.id}", "Elsewhere")
  end
end
