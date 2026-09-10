defmodule RailWeb.Settings.LinearWorkspaceLiveTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Projects
  alias Rail.Projects.Schemas.LinearWorkspace
  alias Rail.Scope
  alias Rail.Users
  alias Rail.Users.Schemas.User

  setup %{conn: conn} do
    id = System.unique_integer([:positive])

    assert {:ok, %User{} = admin_user} =
             Users.register_oauth_user(%{
               github_id: "admin_lw_gh_#{id}",
               login: "admin_lw_#{id}",
               name: "Admin LW #{id}",
               email: "admin_lw_#{id}@example.com",
               avatar_url: "https://example.com/avatar_lw_#{id}.png",
               admin: true
             })

    admin_token = Users.generate_user_session_token(admin_user)

    admin_conn =
      conn
      |> Map.replace!(:secret_key_base, RailWeb.Endpoint.config(:secret_key_base))
      |> init_test_session(%{})
      |> put_session(:user_token, admin_token)

    assert {:ok, %User{} = regular_user} =
             Users.register_oauth_user(%{
               github_id: "regular_lw_gh_#{id}",
               login: "regular_lw_#{id}",
               name: "Regular LW #{id}",
               email: "regular_lw_#{id}@example.com",
               avatar_url: "https://example.com/avatar_regular_lw_#{id}.png",
               admin: false
             })

    regular_token = Users.generate_user_session_token(regular_user)

    regular_conn =
      conn
      |> Map.replace!(:secret_key_base, RailWeb.Endpoint.config(:secret_key_base))
      |> init_test_session(%{})
      |> put_session(:user_token, regular_token)

    %{
      conn: conn,
      admin_conn: admin_conn,
      admin_user: admin_user,
      regular_conn: regular_conn,
      regular_user: regular_user
    }
  end

  test "redirects unauthenticated user to /auth/github", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/auth/github"}}} =
             live(conn, ~p"/settings/linear-workspace")
  end

  test "redirects non-admin user to /", %{regular_conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/settings/linear-workspace")
  end

  test "renders form and validates fields", %{admin_conn: conn} do
    assert {:ok, view, html} = live(conn, ~p"/settings/linear-workspace")
    assert html =~ "Linear Workspace"
    assert html =~ "Workspace Credentials"
    assert has_element?(view, "#save-workspace-button")
    refute has_element?(view, "#workspace-saved-badge")

    view
    |> form("#linear-workspace-form", %{
      "linear_workspace" => %{
        "name" => "",
        "external_id" => "",
        "token" => "",
        "webhook_secret" => ""
      }
    })
    |> render_change()

    assert has_element?(view, "#workspace-name-error", "can't be blank")
    assert has_element?(view, "#workspace-external-id-error", "can't be blank")
    assert has_element?(view, "#workspace-token-error", "can't be blank")
    assert has_element?(view, "#workspace-webhook-secret-error", "can't be blank")
  end

  test "saves new workspace configuration", %{admin_conn: conn} do
    assert {:ok, view, _html} = live(conn, ~p"/settings/linear-workspace")

    id = System.unique_integer([:positive])
    ext_id = "lin_ws_#{id}"

    view
    |> form("#linear-workspace-form", %{
      "linear_workspace" => %{
        "name" => "Company Linear",
        "external_id" => ext_id,
        "token" => "lin_api_tok_live_123",
        "webhook_secret" => "whsec_live_456"
      }
    })
    |> render_submit()

    assert has_element?(view, "#workspace-saved-badge")
  end

  test "prefills existing workspace configuration and saves updates", %{
    admin_conn: conn,
    admin_user: admin
  } do
    scope = Scope.for_user(admin)
    id = System.unique_integer([:positive])
    ext_id = "lin_ws_existing_#{id}"

    assert {:ok, %LinearWorkspace{}} =
             Projects.upsert_linear_workspace(scope, %{
               name: "Existing Workspace",
               external_id: ext_id,
               token: "tok_orig",
               webhook_secret: "whsec_orig"
             })

    assert {:ok, view, html} = live(conn, ~p"/settings/linear-workspace")
    assert html =~ "Existing Workspace"
    assert html =~ ext_id

    view
    |> form("#linear-workspace-form", %{
      "linear_workspace" => %{
        "name" => "Updated Workspace Name",
        "external_id" => ext_id,
        "token" => "tok_new",
        "webhook_secret" => "whsec_new"
      }
    })
    |> render_submit()

    assert has_element?(view, "#workspace-saved-badge")
    assert render(view) =~ "Updated Workspace Name"
  end

  test "renders changeset errors when invalid form is submitted", %{admin_conn: conn} do
    assert {:ok, view, _html} = live(conn, ~p"/settings/linear-workspace")

    view
    |> form("#linear-workspace-form", %{
      "linear_workspace" => %{
        "name" => "",
        "external_id" => "",
        "token" => "",
        "webhook_secret" => ""
      }
    })
    |> render_submit()

    refute has_element?(view, "#workspace-saved-badge")
    assert has_element?(view, "#workspace-name-error", "can't be blank")
  end
end
