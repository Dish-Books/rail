defmodule RailWeb.Settings.ConnectedAccountsLiveTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.GitHub.Client
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users
  alias Rail.Users.Schemas.User

  setup %{conn: conn} do
    id = System.unique_integer([:positive])

    _first =
      Users.register_oauth_user(%{
        github_id: "bootstrap_gh_#{id}",
        login: "bootstrap_user_#{id}",
        name: "Bootstrap Admin #{id}",
        email: "bootstrap_#{id}@example.com"
      })

    assert {:ok, %User{id: user_id} = user} =
             Users.register_oauth_user(%{
               github_id: "live_gh_#{id}",
               login: "live_user_#{id}",
               name: "Live User #{id}",
               email: "live_#{id}@example.com",
               avatar_url: "https://example.com/avatar_#{id}.png"
             })

    user_token = Users.generate_user_session_token(user)

    authed_conn =
      conn
      |> Map.replace!(:secret_key_base, RailWeb.Endpoint.config(:secret_key_base))
      |> init_test_session(%{})
      |> put_session(:user_token, user_token)

    %{conn: conn, authed_conn: authed_conn, user: user, user_id: user_id}
  end

  test "redirects an unauthenticated user to the sign-in page", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/sign-in"}}} =
             live(conn, ~p"/settings/connected-accounts")
  end

  test "renders GitHub section and disconnected Linear section when not linked", %{
    authed_conn: conn,
    user: user
  } do
    assert {:ok, view, html} = live(conn, ~p"/settings/connected-accounts")

    # Settings is the destination lit in the rail, not the overview.
    assert has_element?(view, "#nav-settings[data-active='true']")
    refute has_element?(view, "#nav-overview[data-active='true']")

    assert html =~ "Connected Accounts"
    assert html =~ "Manage third-party services connected to your account"
    assert html =~ "GitHub"
    assert html =~ user.login
    assert html =~ user.name
    assert html =~ user.email
    assert has_element?(view, "#github-avatar")
    assert html =~ "issues and comments go out as the workspace"
    assert has_element?(view, "#connect-linear-button")
    refute has_element?(view, "#disconnect-linear-button")
  end

  test "renders GitHub placeholder avatar when avatar_url is missing", %{conn: conn} do
    id = System.unique_integer([:positive])

    assert {:ok, %User{} = user_no_avatar} =
             Users.register_oauth_user(%{
               github_id: "no_avatar_gh_#{id}",
               login: "no_avatar_#{id}",
               email: "no_avatar_#{id}@example.com",
               avatar_url: nil
             })

    token = Users.generate_user_session_token(user_no_avatar)

    authed_conn =
      conn
      |> Map.replace!(:secret_key_base, RailWeb.Endpoint.config(:secret_key_base))
      |> init_test_session(%{})
      |> put_session(:user_token, token)

    assert {:ok, view, _html} = live(authed_conn, ~p"/settings/connected-accounts")

    # A user with no name falls back to the initial of their login.
    assert has_element?(view, "#github-avatar-placeholder", "N")
  end

  test "counts the repositories Rail can reach as the projects it is configured for", %{authed_conn: conn} do
    assert {:ok, view, _html} = live(conn, ~p"/settings/connected-accounts")
    assert has_element?(view, "#capability-repositories", "Read and write on 1 repository.")

    {:ok, _project} =
      Rail.Projects.create_project(system_scope(), %{
        name: "Second Project",
        github_repo: "org/second-project",
        github_installation_id: 47_030,
        linear_team_key: "TWO",
        default_branch: "main",
        clone_path: "/tmp/repos/second-project"
      })

    assert {:ok, view, _html} = live(conn, ~p"/settings/connected-accounts")
    assert has_element?(view, "#capability-repositories", "Read and write on 2 repositories.")
  end

  test "renders connected Linear section when user is linked", %{
    authed_conn: conn,
    user: user
  } do
    assert {:ok, %User{}} =
             Users.update_user(Scope.for_system(), user, %{
               linear_user_id: "lin_123",
               linear_name: "Jane Doe Linear",
               linear_access_token: "lin_at",
               linear_refresh_token: "lin_rt",
               linear_token_expires_at: DateTime.shift(DateTime.utc_now(), hour: 1)
             })

    assert {:ok, view, html} = live(conn, ~p"/settings/connected-accounts")

    assert html =~ "issues and comments attributed to you"
    assert html =~ "Jane Doe Linear"
    assert has_element?(view, "#disconnect-linear-button")
    refute has_element?(view, "#connect-linear-button")
  end

  test "disconnects Linear when Disconnect button is clicked", %{
    authed_conn: conn,
    user: user,
    user_id: user_id
  } do
    assert {:ok, %User{}} =
             Users.update_user(Scope.for_system(), user, %{
               linear_user_id: "lin_disconnect_id",
               linear_name: "Disconnect User",
               linear_access_token: "lin_at_disconnect",
               linear_refresh_token: "lin_rt_disconnect",
               linear_token_expires_at: DateTime.shift(DateTime.utc_now(), hour: 1)
             })

    assert {:ok, view, _html} = live(conn, ~p"/settings/connected-accounts")
    assert has_element?(view, "#disconnect-linear-button")

    rendered =
      view
      |> element("#disconnect-linear-button")
      |> render_click()

    assert rendered =~ "issues and comments go out as the workspace"
    assert has_element?(view, "#connect-linear-button")
    refute has_element?(view, "#disconnect-linear-button")

    reloaded = Repo.get!(User, user_id)
    assert is_nil(reloaded.linear_access_token)
    assert is_nil(reloaded.linear_user_id)
  end

  test "handles disconnect error gracefully when the user cannot be updated", %{
    authed_conn: conn,
    user: user
  } do
    assert {:ok, %User{}} =
             Users.update_user(Scope.for_system(), user, %{
               linear_access_token: "lin_at_err_test",
               linear_refresh_token: "lin_rt_err_test",
               linear_token_expires_at: DateTime.shift(DateTime.utc_now(), hour: 1)
             })

    assert {:ok, view, _html} = live(conn, ~p"/settings/connected-accounts")

    expect(Users, :unlink_linear, fn _scope -> {:error, :db_error} end)

    rendered = render_click(element(view, "#disconnect-linear-button"))
    assert rendered =~ "issues and comments attributed to you"
  end

  test "lists enabled OAuth MCP servers to connect and disconnect", %{authed_conn: conn, user: user} do
    {:ok, linear} =
      Rail.Mcp.create_server(system_scope(), %{name: "ca_linear", url: "https://mcp.linear.app/mcp"})

    {:ok, %{id: sentry_id}} =
      Rail.Mcp.create_server(system_scope(), %{name: "ca_sentry", url: "https://mcp.sentry.dev/mcp"})

    {:ok, _open} =
      Rail.Mcp.create_server(system_scope(), %{name: "ca_open", url: "https://o.example.com", auth: :none})

    {:ok, _off} =
      Rail.Mcp.create_server(system_scope(), %{
        name: "ca_off",
        url: "https://off.example.com",
        enabled: false
      })

    Repo.insert!(%Rail.Mcp.Schemas.McpConnection{user_id: user.id, mcp_server_id: linear.id, access_token: "at"})

    assert {:ok, view, _html} = live(conn, ~p"/settings/connected-accounts")

    assert has_element?(view, "#disconnect-mcp-ca_linear")
    assert has_element?(view, "#connect-mcp-ca_sentry[href='/auth/mcp/#{sentry_id}']")
    refute has_element?(view, "#mcp-server-section-ca_open")
    refute has_element?(view, "#mcp-server-section-ca_off")

    view |> element("#disconnect-mcp-ca_linear") |> render_click()
    assert has_element?(view, "#connect-mcp-ca_linear")
    assert [] = Rail.Mcp.list_connections(Scope.for_user(user))

    render_click(view, "disconnect_mcp", %{"id" => "mcs_missing"})
    assert has_element?(view, "#connect-mcp-ca_linear")
  end

  test "renders only connected accounts tab for non-admin user", %{authed_conn: conn} do
    assert {:ok, view, _html} = live(conn, ~p"/settings/connected-accounts")
    assert has_element?(view, "#tab-connected-accounts")
    refute has_element?(view, "#tab-projects")
  end

  test "renders all settings tabs for admin user", %{conn: conn} do
    id = System.unique_integer([:positive])

    assert {:ok, %User{} = admin} =
             Users.register_oauth_user(%{
               github_id: "admin_tabs_gh_#{id}",
               login: "admin_tabs_#{id}",
               name: "Admin Tabs",
               email: "admin_tabs_#{id}@example.com",
               admin: true
             })

    admin_token = Users.generate_user_session_token(admin)

    admin_conn =
      conn
      |> Map.replace!(:secret_key_base, RailWeb.Endpoint.config(:secret_key_base))
      |> init_test_session(%{})
      |> put_session(:user_token, admin_token)

    assert {:ok, view, _html} = live(admin_conn, ~p"/settings/connected-accounts")
    assert has_element?(view, "#tab-connected-accounts")
    assert has_element?(view, "#tab-projects")
  end

  describe "commit signing" do
    test "offers to set it up when there is no key", %{authed_conn: conn} do
      assert {:ok, view, _html} = live(conn, ~p"/settings/connected-accounts")

      assert has_element?(view, "#commit-signing-message", "Not set up")
      assert has_element?(view, "#set-up-signing-button", "Set up commit signing")
      refute has_element?(view, "#remove-signing-button")
    end

    test "generates a key, registers it with GitHub and shows its fingerprint", %{authed_conn: conn, user: user} do
      {:ok, _tokened} = Users.update_user(system_scope(), user, %{github_token: "gho_user_token"})

      Req.Test.expect(Client, fn req_conn ->
        req_conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => 4711})
      end)

      assert {:ok, view, _html} = live(conn, ~p"/settings/connected-accounts")

      view |> element("#set-up-signing-button") |> render_click()

      assert has_element?(view, "[data-qa='commit_signing_fingerprint']", "SHA256:")
      assert has_element?(view, "#remove-signing-button")
    end

    test "says to sign in again when GitHub has not granted the scope", %{authed_conn: conn, user: user} do
      {:ok, _tokened} = Users.update_user(system_scope(), user, %{github_token: "gho_user_token"})

      Req.Test.expect(Client, fn req_conn ->
        req_conn |> Plug.Conn.put_status(403) |> Req.Test.json(%{"message" => "Resource not accessible"})
      end)

      assert {:ok, view, _html} = live(conn, ~p"/settings/connected-accounts")

      view |> element("#set-up-signing-button") |> render_click()

      assert has_element?(view, "[data-qa='commit_signing_error']", "SSH signing keys permission")
    end

    test "says to sign in again when Rail holds no GitHub token", %{authed_conn: conn} do
      assert {:ok, view, _html} = live(conn, ~p"/settings/connected-accounts")

      view |> element("#set-up-signing-button") |> render_click()

      assert has_element?(view, "[data-qa='commit_signing_error']", "Sign in with GitHub again")
    end

    test "says what came back when GitHub refused the key outright", %{authed_conn: conn, user: user} do
      {:ok, _tokened} = Users.update_user(system_scope(), user, %{github_token: "gho_user_token"})

      Req.Test.expect(Client, fn req_conn ->
        req_conn |> Plug.Conn.put_status(422) |> Req.Test.json(%{"message" => "key is already in use"})
      end)

      assert {:ok, view, _html} = live(conn, ~p"/settings/connected-accounts")

      view |> element("#set-up-signing-button") |> render_click()

      assert has_element?(view, "[data-qa='commit_signing_error']", "Could not set up commit signing")
    end

    test "removing the key takes it off GitHub and forgets it", %{authed_conn: conn, user: user} do
      {:ok, _tokened} = Users.update_user(system_scope(), user, %{github_token: "gho_user_token"})

      Req.Test.expect(Client, fn req_conn ->
        req_conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => 4711})
      end)

      assert {:ok, view, _html} = live(conn, ~p"/settings/connected-accounts")
      view |> element("#set-up-signing-button") |> render_click()

      Req.Test.expect(Client, fn req_conn -> Plug.Conn.send_resp(req_conn, 204, "") end)

      view |> element("#remove-signing-button") |> render_click()

      assert has_element?(view, "#commit-signing-message", "Not set up")
      assert %User{signing_key: nil} = Repo.reload!(user)
    end
  end
end
