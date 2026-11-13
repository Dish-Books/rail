defmodule RailWeb.Settings.ConnectedAccountsLiveTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.GitHub.Client
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Slack
  alias Rail.Users
  alias Rail.Users.Schemas.User

  setup {Req.Test, :verify_on_exit!}

  setup %{conn: conn, project: project} do
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

    {:ok, user} = Users.update_user(system_scope(), user, %{project_ids: [project.id]})

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

  test "counts the repositories Rail can reach as the projects the user can access", %{
    authed_conn: conn,
    user: user,
    project: project
  } do
    assert {:ok, view, _html} = live(conn, ~p"/settings/connected-accounts")
    assert has_element?(view, "#capability-repositories", "Read and write on 1 repository.")

    {:ok, second} =
      Projects.create_project(system_scope(), %{
        name: "Second Project",
        github_repo: "org/second-project",
        github_installation_id: 47_030,
        key: "TWOCA",
        default_branch: "main",
        clone_path: "/tmp/repos/second-project"
      })

    assert {:ok, view, _html} = live(conn, ~p"/settings/connected-accounts")
    assert has_element?(view, "#capability-repositories", "Read and write on 1 repository.")

    {:ok, _user} = Users.update_user(system_scope(), user, %{project_ids: [project.id, second.id]})

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
      {:ok, _tokened} =
        Users.update_user(system_scope(), user, %{
          github_token: "gho_user_token",
          github_token_expires_at: ~U[2100-01-01 00:00:00.000000Z]
        })

      Req.Test.expect(Client, fn req_conn ->
        req_conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => 4711})
      end)

      assert {:ok, view, _html} = live(conn, ~p"/settings/connected-accounts")

      view |> element("#set-up-signing-button") |> render_click()

      assert has_element?(view, "[data-qa='commit_signing_fingerprint']", "SHA256:")
      assert has_element?(view, "#remove-signing-button")
    end

    test "says to sign in again when GitHub has not granted the scope", %{authed_conn: conn, user: user} do
      {:ok, _tokened} =
        Users.update_user(system_scope(), user, %{
          github_token: "gho_user_token",
          github_token_expires_at: ~U[2100-01-01 00:00:00.000000Z]
        })

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
      {:ok, _tokened} =
        Users.update_user(system_scope(), user, %{
          github_token: "gho_user_token",
          github_token_expires_at: ~U[2100-01-01 00:00:00.000000Z]
        })

      Req.Test.expect(Client, fn req_conn ->
        req_conn |> Plug.Conn.put_status(422) |> Req.Test.json(%{"message" => "key is already in use"})
      end)

      assert {:ok, view, _html} = live(conn, ~p"/settings/connected-accounts")

      view |> element("#set-up-signing-button") |> render_click()

      assert has_element?(view, "[data-qa='commit_signing_error']", "Could not set up commit signing")
    end

    test "removing the key takes it off GitHub and forgets it", %{authed_conn: conn, user: user} do
      {:ok, _tokened} =
        Users.update_user(system_scope(), user, %{
          github_token: "gho_user_token",
          github_token_expires_at: ~U[2100-01-01 00:00:00.000000Z]
        })

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

    test "removing a key GitHub will not take the token for says to sign in again, and keeps the key", %{
      authed_conn: conn,
      user: user
    } do
      {:ok, _tokened} =
        Users.update_user(system_scope(), user, %{
          github_token: "gho_user_token",
          github_token_expires_at: ~U[2100-01-01 00:00:00.000000Z]
        })

      Req.Test.expect(Client, fn req_conn ->
        req_conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => 4711})
      end)

      assert {:ok, view, _html} = live(conn, ~p"/settings/connected-accounts")
      view |> element("#set-up-signing-button") |> render_click()

      Req.Test.expect(Client, fn req_conn ->
        req_conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"message" => "Bad credentials"})
      end)

      view |> element("#remove-signing-button") |> render_click()

      assert has_element?(view, "[data-qa='commit_signing_error']", "Sign in with GitHub again")
      assert has_element?(view, "#remove-signing-button")
      assert %User{signing_key_github_id: 4711} = Repo.reload!(user)
    end
  end

  test "connects and disconnects Slack, so triage posts as you", %{authed_conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/settings/connected-accounts")

    assert has_element?(view, "#slack-disconnected-message")
    assert has_element?(view, ~s(#connect-slack-button[href="/auth/slack"]))

    {:ok, _linked} =
      Users.update_user(system_scope(), user, %{
        slack_name: "Live Slack",
        slack_access_token: "xoxp-1",
        slack_team_id: "T1"
      })

    {:ok, view, _html} = live(conn, ~p"/settings/connected-accounts")
    assert has_element?(view, "#slack-connected-details", "Live Slack")

    view |> element("#disconnect-slack-button") |> render_click()

    assert has_element?(view, "#connect-slack-button")
    assert %User{slack_access_token: nil} = Repo.reload!(user)
  end

  test "a Slack disconnect that fails changes nothing on the page", %{authed_conn: conn, user: user} do
    {:ok, _linked} = Users.update_user(system_scope(), user, %{slack_access_token: "xoxp-1"})
    expect(Users, :unlink_slack, fn _scope -> {:error, :db_error} end)

    {:ok, view, _html} = live(conn, ~p"/settings/connected-accounts")
    view |> element("#disconnect-slack-button") |> render_click()

    assert has_element?(view, "#disconnect-slack-button")
  end

  describe "Slack notifications" do
    setup do
      team_id = "T#{System.unique_integer([:positive])}"
      Req.Test.expect(Slack, &Req.Test.json(&1, %{"ok" => true, "team_id" => team_id}))
      {:ok, _workspace} = Projects.create_slack_workspace(system_scope(), %{"name" => "Acme", "token" => "xoxb-ca"})
      %{team_id: team_id}
    end

    test "cannot be turned on without Slack connected", %{authed_conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/connected-accounts")

      assert has_element?(view, "#slack-notifications-message", "Connect Slack to get notifications.")
      assert has_element?(view, "#slack-notifications-state", "Off")
      assert has_element?(view, "#slack-notifications-switch[disabled]")
      assert has_element?(view, "#slack-notifications-switch[aria-checked='false']")
    end

    test "turn on with a first message, stay on after a reload, and turn off sending nothing", %{
      authed_conn: conn,
      user: user,
      team_id: team_id
    } do
      {:ok, _linked} =
        Users.update_user(system_scope(), user, %{
          slack_user_id: "U1",
          slack_team_id: team_id,
          slack_access_token: "xoxp-1"
        })

      test_pid = self()

      Req.Test.expect(Slack, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert ["Bearer xoxb-ca"] = Plug.Conn.get_req_header(conn, "authorization")
        send(test_pid, {:posted, Jason.decode!(body)})
        Req.Test.json(conn, %{"ok" => true, "ts" => "1790000000.000100"})
      end)

      {:ok, view, _html} = live(conn, ~p"/settings/connected-accounts")
      assert has_element?(view, "#slack-notifications-message", "Off. Rail sends you nothing in Slack.")
      refute has_element?(view, "#slack-notifications-switch[disabled]")

      view |> element("#slack-notifications-switch") |> render_click()

      assert_received {:posted, %{"channel" => "U1", "text" => "Rail will message you here" <> _rest}}
      assert has_element?(view, "#slack-notifications-state", "On")
      assert %User{slack_notifications: true} = Repo.reload!(user)

      {:ok, view, _html} = live(conn, ~p"/settings/connected-accounts")
      assert has_element?(view, "#slack-notifications-switch[aria-checked='true']")

      assert has_element?(
               view,
               "#slack-notifications-message",
               "Rail messages you when a task you own waits on you, and when someone else merges it."
             )

      # No Slack expectation is left, so a request here would fail the test.
      view |> element("#slack-notifications-switch") |> render_click()

      assert has_element?(view, "#slack-notifications-state", "Off")
      assert has_element?(view, "#slack-notifications-switch[aria-checked='false']")
      assert %User{slack_notifications: false} = Repo.reload!(user)
    end

    test "a refused first message keeps the switch Off with the reason, and a retry that gets through clears it", %{
      authed_conn: conn,
      user: user,
      team_id: team_id
    } do
      {:ok, _linked} =
        Users.update_user(system_scope(), user, %{
          slack_user_id: "U1",
          slack_team_id: team_id,
          slack_access_token: "xoxp-1"
        })

      Req.Test.expect(Slack, &Req.Test.json(&1, %{"ok" => false, "error" => "messages_tab_disabled"}))

      {:ok, view, _html} = live(conn, ~p"/settings/connected-accounts")
      view |> element("#slack-notifications-switch") |> render_click()

      assert has_element?(
               view,
               "#slack-notifications-error[role='alert']",
               "The Rail app's Messages tab is off, so Slack refused the message. " <>
                 "An admin turns it on under App Home in the Slack app's settings."
             )

      refute has_element?(view, "#slack-notifications-message")
      assert has_element?(view, "#slack-notifications-state", "Off")
      assert has_element?(view, "#slack-notifications-switch[aria-checked='false']")
      assert %User{slack_notifications: false} = Repo.reload!(user)

      # A change to the user that leaves notifications off keeps the reason up.
      {:ok, _renamed} = Users.update_user(system_scope(), Repo.reload!(user), %{name: "Renamed"})
      assert has_element?(view, "#slack-notifications-error")

      Req.Test.expect(Slack, &Req.Test.json(&1, %{"ok" => true, "ts" => "1790000000.000100"}))
      view |> element("#slack-notifications-switch") |> render_click()

      refute has_element?(view, "#slack-notifications-error")
      assert has_element?(view, "#slack-notifications-state", "On")
      assert has_element?(view, "#slack-notifications-switch[aria-checked='true']")
      assert %User{slack_notifications: true} = Repo.reload!(user)
    end

    test "names each other reason Slack refuses for", %{authed_conn: conn, user: user, team_id: team_id} do
      {:ok, _linked} =
        Users.update_user(system_scope(), user, %{
          slack_user_id: "U1",
          slack_team_id: team_id,
          slack_access_token: "xoxp-1"
        })

      {:ok, view, _html} = live(conn, ~p"/settings/connected-accounts")

      for {answer, reason} <- [
            {%{"ok" => false, "error" => "invalid_auth"},
             "Slack refused the message because the workspace's bot token is no longer valid. " <>
               "An admin replaces it under Settings, Slack."},
            {%{"ok" => false, "error" => "channel_not_found"},
             "Slack refused the message: channel_not_found. An admin checks the Rail app's settings at api.slack.com/apps."}
          ] do
        Req.Test.expect(Slack, &Req.Test.json(&1, answer))
        view |> element("#slack-notifications-switch") |> render_click()
        assert has_element?(view, "#slack-notifications-error", reason)
      end

      Req.Test.expect(Slack, &Plug.Conn.send_resp(&1, 503, ""))
      view |> element("#slack-notifications-switch") |> render_click()
      assert has_element?(view, "#slack-notifications-error", "Rail could not reach Slack. Try again.")

      assert has_element?(view, "#slack-notifications-switch[aria-checked='false']")
      assert %User{slack_notifications: false} = Repo.reload!(user)
    end

    test "says so when Rail has no workspace for the user's Slack team", %{authed_conn: conn, user: user} do
      {:ok, _linked} =
        Users.update_user(system_scope(), user, %{
          slack_user_id: "U1",
          slack_team_id: "T_ELSEWHERE",
          slack_access_token: "xoxp-1"
        })

      {:ok, view, _html} = live(conn, ~p"/settings/connected-accounts")
      view |> element("#slack-notifications-switch") |> render_click()

      assert has_element?(
               view,
               "#slack-notifications-error",
               "Rail has no Slack workspace for your Slack account. An admin adds it under Settings, Slack."
             )

      assert %User{slack_notifications: false} = Repo.reload!(user)
    end

    test "a stale tab still showing Off sets On again with no second message", %{
      authed_conn: conn,
      user: user,
      team_id: team_id
    } do
      {:ok, _linked} =
        Users.update_user(system_scope(), user, %{
          slack_user_id: "U1",
          slack_team_id: team_id,
          slack_access_token: "xoxp-1"
        })

      Req.Test.expect(Slack, &Req.Test.json(&1, %{"ok" => true, "ts" => "1790000000.000100"}))

      {:ok, first, _html} = live(conn, ~p"/settings/connected-accounts")
      {:ok, second, _html} = live(conn, ~p"/settings/connected-accounts")

      first |> element("#slack-notifications-switch") |> render_click()
      # What a tab that has not caught up yet sends.
      render_click(second, "set_slack_notifications", %{"on" => "true"})

      assert has_element?(second, "#slack-notifications-state", "On")
      assert %User{slack_notifications: true} = Repo.reload!(user)
    end

    test "a tab showing a refusal catches up to On when another tab turns them on", %{
      authed_conn: conn,
      user: user,
      team_id: team_id
    } do
      {:ok, _linked} =
        Users.update_user(system_scope(), user, %{
          slack_user_id: "U1",
          slack_team_id: team_id,
          slack_access_token: "xoxp-1"
        })

      {:ok, first, _html} = live(conn, ~p"/settings/connected-accounts")
      {:ok, second, _html} = live(conn, ~p"/settings/connected-accounts")

      Req.Test.expect(Slack, &Req.Test.json(&1, %{"ok" => false, "error" => "messages_tab_disabled"}))
      first |> element("#slack-notifications-switch") |> render_click()
      assert has_element?(first, "#slack-notifications-error")

      Req.Test.expect(Slack, &Req.Test.json(&1, %{"ok" => true, "ts" => "1790000000.000100"}))
      second |> element("#slack-notifications-switch") |> render_click()

      refute has_element?(first, "#slack-notifications-error")
      assert has_element?(first, "#slack-notifications-state", "On")
      assert has_element?(first, "#slack-notifications-switch[aria-checked='true']")
    end

    test "ignore a change to someone else", %{authed_conn: conn, user: user, team_id: team_id} do
      {:ok, _linked} =
        Users.update_user(system_scope(), user, %{
          slack_user_id: "U1",
          slack_team_id: team_id,
          slack_access_token: "xoxp-1"
        })

      id = System.unique_integer([:positive])

      {:ok, other} =
        Users.register_oauth_user(%{github_id: "other_#{id}", login: "other_#{id}", email: "other_#{id}@example.com"})

      Req.Test.expect(Slack, &Req.Test.json(&1, %{"ok" => false, "error" => "messages_tab_disabled"}))

      {:ok, view, _html} = live(conn, ~p"/settings/connected-accounts")
      view |> element("#slack-notifications-switch") |> render_click()

      {:ok, _renamed} = Users.update_user(system_scope(), other, %{name: "Someone Else"})

      assert has_element?(view, "#slack-notifications-error")
      assert has_element?(view, "#github-login", user.login)
    end

    test "read Off once Slack is disconnected, with a refusal's reason gone", %{
      authed_conn: conn,
      user: user,
      team_id: team_id
    } do
      {:ok, _linked} =
        Users.update_user(system_scope(), user, %{
          slack_user_id: "U1",
          slack_team_id: team_id,
          slack_access_token: "xoxp-1"
        })

      Req.Test.expect(Slack, &Req.Test.json(&1, %{"ok" => false, "error" => "messages_tab_disabled"}))

      {:ok, view, _html} = live(conn, ~p"/settings/connected-accounts")
      view |> element("#slack-notifications-switch") |> render_click()
      assert has_element?(view, "#slack-notifications-error")

      view |> element("#disconnect-slack-button") |> render_click()

      refute has_element?(view, "#slack-notifications-error")
      assert has_element?(view, "#slack-notifications-message", "Connect Slack to get notifications.")
      assert has_element?(view, "#slack-notifications-state", "Off")
      assert has_element?(view, "#slack-notifications-switch[disabled]")
      assert %User{slack_notifications: false} = Repo.reload!(user)
    end

    test "read Off once Slack is disconnected while on", %{authed_conn: conn, user: user, team_id: team_id} do
      {:ok, linked} =
        Users.update_user(system_scope(), user, %{
          slack_user_id: "U1",
          slack_team_id: team_id,
          slack_access_token: "xoxp-1"
        })

      Req.Test.expect(Slack, &Req.Test.json(&1, %{"ok" => true, "ts" => "1790000000.000100"}))
      {:ok, _on} = Users.set_slack_notifications(Scope.for_user(linked), true)

      {:ok, view, _html} = live(conn, ~p"/settings/connected-accounts")
      view |> element("#disconnect-slack-button") |> render_click()

      assert has_element?(view, "#slack-notifications-state", "Off")
      assert has_element?(view, "#slack-notifications-switch[disabled]")
      assert %User{slack_notifications: false} = Repo.reload!(user)
    end

    test "turned on after Slack was disconnected in another tab, the page catches up", %{
      authed_conn: conn,
      user: user,
      team_id: team_id
    } do
      {:ok, linked} =
        Users.update_user(system_scope(), user, %{
          slack_user_id: "U1",
          slack_team_id: team_id,
          slack_access_token: "xoxp-1"
        })

      {:ok, view, _html} = live(conn, ~p"/settings/connected-accounts")
      {:ok, _unlinked} = Users.unlink_slack(Scope.for_user(linked))

      view |> element("#slack-notifications-switch") |> render_click()

      assert has_element?(view, "#connect-slack-button")
      assert has_element?(view, "#slack-notifications-switch[disabled]")
      assert %User{slack_notifications: false} = Repo.reload!(user)
    end
  end

  describe "Rail MCP" do
    setup %{user: user} do
      {:ok, code_client, nil} =
        Rail.Mcp.register_dynamic_client(%{
          "client_name" => "Claude Code",
          "redirect_uris" => ["http://localhost/callback"]
        })

      {:ok, web_client, nil} =
        Rail.Mcp.register_dynamic_client(%{"client_name" => "Claude", "redirect_uris" => ["https://claude.ai/callback"]})

      connect = fn client ->
        verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
        [redirect_uri] = client.redirect_uris

        {:ok, %{redirect_url: url}} =
          Rail.Mcp.authorize(Scope.for_user(user), %{
            "client_id" => client.client_id,
            "redirect_uri" => redirect_uri,
            "code_challenge" => Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false),
            "code_challenge_method" => "S256"
          })

        {:ok, %{access_token: access_token}} =
          Rail.Mcp.exchange_code(client, %{
            "grant_type" => "authorization_code",
            "code" => URI.decode_query(URI.parse(url).query)["code"],
            "redirect_uri" => redirect_uri,
            "code_verifier" => verifier
          })

        access_token
      end

      %{code_client: code_client, web_client: web_client, connect: connect}
    end

    test "shows the address and the Claude Code command, and says when no Claude is connected", %{authed_conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/connected-accounts")
      address = RailWeb.Endpoint.url() <> "/mcp"

      assert has_element?(view, "#rail-mcp-url", address)
      assert has_element?(view, "#rail-mcp-claude-code", "claude mcp add --transport http rail #{address}")
      assert has_element?(view, "#copy-rail-mcp-url[data-copy-text='#{address}']")
      assert has_element?(view, "#rail-mcp-description", "in the 1 project you can open")
      assert has_element?(view, "#rail-mcp-empty", "No Claude connected")
      refute has_element?(view, "#rail-mcp-connections")
    end

    test "lists one row per connection, newest first, and one made elsewhere shows without a reload", %{
      authed_conn: conn,
      code_client: code_client,
      web_client: web_client,
      connect: connect
    } do
      connect.(web_client)
      {:ok, view, _html} = live(conn, ~p"/settings/connected-accounts")
      assert has_element?(view, "#rail-mcp-connections tbody tr", "Returns to claude.ai")

      connect.(code_client)

      assert [_header, newest, oldest] =
               view
               |> render()
               |> LazyHTML.from_fragment()
               |> LazyHTML.query("#rail-mcp-connections tr")
               |> Enum.to_list()

      assert LazyHTML.text(newest) =~ "Claude Code"
      assert LazyHTML.text(newest) =~ "Returns to localhost"
      assert LazyHTML.text(oldest) =~ "Returns to claude.ai"
      refute has_element?(view, "#rail-mcp-empty")
    end

    test "Revoke asks first, then refuses that Claude and leaves the others", %{
      authed_conn: conn,
      user: user,
      code_client: code_client,
      web_client: web_client,
      connect: connect
    } do
      kept = connect.(web_client)
      revoked = connect.(code_client)
      [%{family_id: family_id}, %{family_id: kept_family}] = Rail.Mcp.list_authorizations(Scope.for_user(user))
      {:ok, view, _html} = live(conn, ~p"/settings/connected-accounts")

      view |> element("#revoke-rail-mcp-#{family_id}") |> render_click()
      assert has_element?(view, "#revoke-rail-mcp-modal", "Revoke this Claude connection?")

      view |> element("#cancel-revoke-rail-mcp") |> render_click()
      refute has_element?(view, "#revoke-rail-mcp-modal")
      assert {:ok, %Scope{}} = Rail.Mcp.resolve_access_token(revoked)

      view |> element("#revoke-rail-mcp-#{family_id}") |> render_click()
      view |> element("#revoke-rail-mcp-modal") |> render_keydown(%{"key" => "Escape"})
      refute has_element?(view, "#revoke-rail-mcp-modal")

      view |> element("#revoke-rail-mcp-#{family_id}") |> render_click()
      view |> element("#confirm-revoke-rail-mcp") |> render_click()

      refute has_element?(view, "#revoke-rail-mcp-modal")
      refute has_element?(view, "#rail-mcp-connection-#{family_id}")
      assert has_element?(view, "#rail-mcp-connection-#{kept_family}")
      assert {:error, :revoked} = Rail.Mcp.resolve_access_token(revoked)
      assert {:ok, %Scope{}} = Rail.Mcp.resolve_access_token(kept)
    end

    test "a connection revoked in another tab while its modal is open closes it, and a confirm then does nothing", %{
      authed_conn: conn,
      user: user,
      code_client: code_client,
      connect: connect
    } do
      connect.(code_client)
      [%{family_id: family_id}] = Rail.Mcp.list_authorizations(Scope.for_user(user))
      {:ok, view, _html} = live(conn, ~p"/settings/connected-accounts")
      view |> element("#revoke-rail-mcp-#{family_id}") |> render_click()

      :ok = Rail.Mcp.revoke_authorization(Scope.for_user(user), family_id)

      refute has_element?(view, "#revoke-rail-mcp-modal")
      assert has_element?(view, "#rail-mcp-empty")
      render_click(view, "confirm_revoke_mcp", %{})
      assert has_element?(view, "#rail-mcp-empty")
    end

    test "a use elsewhere updates Last used without a reload, and another person's changes are ignored", %{
      authed_conn: conn,
      user: user,
      code_client: code_client,
      connect: connect
    } do
      access_token = connect.(code_client)
      [%{family_id: family_id}] = Rail.Mcp.list_authorizations(Scope.for_user(user))
      Repo.update_all(Rail.Mcp.Schemas.OauthAccessToken, set: [inserted_at: ~U[2026-01-02 03:04:05Z]])
      {:ok, view, _html} = live(conn, ~p"/settings/connected-accounts")
      assert has_element?(view, "#rail-mcp-last-used-#{family_id}", "Jan 2, 3:04 AM UTC")

      send(view.pid, {:mcp_authorizations_changed, "usr_someone_else"})
      {:ok, _scope} = Rail.Mcp.resolve_access_token(access_token)

      refute has_element?(view, "#rail-mcp-last-used-#{family_id}", "Jan 2, 3:04 AM UTC")
      assert has_element?(view, "#rail-mcp-connected-#{family_id}", "Jan 2, 3:04 AM UTC")
    end
  end
end
