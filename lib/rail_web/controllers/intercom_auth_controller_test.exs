defmodule RailWeb.IntercomAuthControllerTest do
  use RailWeb.ConnCase, async: true

  alias Rail.Repo
  alias Rail.Support
  alias Rail.Users
  alias Rail.Users.Schemas.User

  setup %{conn: conn} do
    unique = System.unique_integer([:positive])
    app_id = "app#{unique}"
    project = :persistent_term.get({RailTest, :project})

    {:ok, user} =
      Users.register_oauth_user(%{github_id: "iac_#{unique}", login: "iac_#{unique}", email: "iac_#{unique}@example.com"})

    Req.Test.expect(Rail.Intercom, &Req.Test.json(&1, %{"app" => %{"id_code" => app_id}}))

    {:ok, workspace} =
      Support.create_intercom_workspace(system_scope(), project, %{
        "name" => "Support",
        "access_token" => "tok",
        "client_id" => "cid_#{unique}",
        "client_secret" => "secret"
      })

    %{conn: log_in_user(conn, user), user: user, workspace: workspace, app_id: app_id}
  end

  test "sends the person to Intercom with a state, remembering which workspace", %{
    conn: conn,
    workspace: %{id: workspace_id}
  } do
    conn = get(conn, ~p"/auth/intercom?#{[workspace_id: workspace_id]}")

    state = get_session(conn, :intercom_oauth_state)
    assert ^workspace_id = get_session(conn, :intercom_oauth_workspace_id)
    assert "https://app.intercom.com/oauth?" <> query = redirected_to(conn, 302)

    assert %{"client_id" => "cid_" <> _unique, "state" => ^state, "redirect_uri" => "http" <> redirect} =
             URI.decode_query(query)

    assert String.ends_with?(redirect, "/auth/intercom/callback")
  end

  test "a workspace no longer connected, or none picked, goes back with an error", %{conn: conn} do
    gone = get(conn, ~p"/auth/intercom?#{[workspace_id: "iw_gone"]}")
    assert redirected_to(gone) == ~p"/settings/connected-accounts"
    assert Phoenix.Flash.get(gone.assigns.flash, :error) =~ "no longer connected"

    none = get(conn, ~p"/auth/intercom")
    assert Phoenix.Flash.get(none.assigns.flash, :error) =~ "Pick an Intercom workspace"
  end

  test "a good state links the account", %{conn: conn, user: user, workspace: workspace, app_id: app_id} do
    Req.Test.expect(Rail.Intercom, &Req.Test.json(&1, %{"access_token" => "dana-token"}))

    Req.Test.expect(Rail.Intercom, fn conn ->
      Req.Test.json(conn, %{"id" => 7, "name" => "Dana", "email_verified" => true, "app" => %{"id_code" => app_id}})
    end)

    conn =
      conn
      |> put_session(:intercom_oauth_state, "st")
      |> put_session(:intercom_oauth_workspace_id, workspace.id)
      |> get(~p"/auth/intercom/callback", %{"code" => "c0de", "state" => "st"})

    assert redirected_to(conn) == ~p"/settings/connected-accounts"
    assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Connected Intercom account"
    assert %User{intercom_access_token: "dana-token", intercom_name: "Dana"} = Repo.reload!(user)
    refute get_session(conn, :intercom_oauth_state)
    refute get_session(conn, :intercom_oauth_workspace_id)
  end

  test "an account Intercom does not confirm for the workspace is refused", %{conn: conn, workspace: workspace} do
    Req.Test.expect(Rail.Intercom, &Req.Test.json(&1, %{"access_token" => "tok"}))
    Req.Test.expect(Rail.Intercom, &Req.Test.json(&1, %{"id" => 7, "email_verified" => false}))

    conn =
      conn
      |> put_session(:intercom_oauth_state, "st")
      |> put_session(:intercom_oauth_workspace_id, workspace.id)
      |> get(~p"/auth/intercom/callback", %{"code" => "c0de", "state" => "st"})

    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "did not confirm this account"
  end

  test "a code Intercom refuses is reported", %{conn: conn, workspace: workspace} do
    Req.Test.expect(Rail.Intercom, &(&1 |> Plug.Conn.put_status(400) |> Req.Test.json(%{})))

    conn =
      conn
      |> put_session(:intercom_oauth_state, "st")
      |> put_session(:intercom_oauth_workspace_id, workspace.id)
      |> get(~p"/auth/intercom/callback", %{"code" => "c0de", "state" => "st"})

    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Failed to connect Intercom account"
  end

  test "a bad or missing state is refused without asking Intercom", %{conn: conn, user: user, workspace: workspace} do
    forged =
      conn
      |> put_session(:intercom_oauth_state, "real")
      |> put_session(:intercom_oauth_workspace_id, workspace.id)
      |> get(~p"/auth/intercom/callback", %{"code" => "c0de", "state" => "forged"})

    assert Phoenix.Flash.get(forged.assigns.flash, :error) =~ "Intercom authentication failed"

    missing = get(conn, ~p"/auth/intercom/callback", %{"code" => "c0de", "state" => "st"})
    assert Phoenix.Flash.get(missing.assigns.flash, :error) =~ "Intercom authentication failed"
    assert %User{intercom_access_token: nil} = Repo.reload!(user)
  end

  test "a denied request redirects with an error", %{conn: conn} do
    conn = get(conn, ~p"/auth/intercom/callback", %{"error" => "access_denied"})

    assert redirected_to(conn) == ~p"/settings/connected-accounts"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "denied or cancelled"
  end
end
