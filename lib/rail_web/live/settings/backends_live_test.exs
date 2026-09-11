defmodule RailWeb.Settings.BackendsLiveTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Backends
  alias Rail.Backends.Schemas.CliAccount
  alias Rail.Domain.Embeds.CliAccountGroup
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users

  test "redirects unauthenticated user to /auth/github", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/auth/github"}}} = live(conn, ~p"/settings/backends")
  end

  test "redirects non-admin user to /", %{conn: conn} do
    # The first registered user is promoted to admin, so seed one before the regular user
    {:ok, admin} =
      Users.register_oauth_user(%{
        github_id: "gh_backends_live_1",
        login: "backends_live_user_1",
        email: "backends_live_user_1@example.com",
        admin: true
      })

    _admin_conn = log_in_user(conn, admin)

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_backends_live_2",
        login: "backends_live_user_2",
        email: "backends_live_user_2@example.com",
        admin: false
      })

    regular_conn = log_in_user(conn, user)

    assert {:error, {:redirect, %{to: "/"}}} = live(regular_conn, ~p"/settings/backends")
  end

  test "renders a card per backend, unconfigured by default", %{conn: conn} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_backends_live_3",
        login: "backends_live_user_3",
        email: "backends_live_user_3@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)

    assert {:ok, view, _html} = live(authed_conn, ~p"/settings/backends")

    assert has_element?(view, "#backends-settings")
    assert has_element?(view, "#backends-title", "Backends")
    assert has_element?(view, "#tab-backends")

    for name <- Backends.backend_names() do
      assert has_element?(view, "#backend-card-#{name}")
      assert has_element?(view, "#executable-path-#{name}")
      assert has_element?(view, "#no-models-#{name}")
      assert has_element?(view, "#status-badge-#{name}", "Not Configured")
    end

    assert has_element?(view, "#backend-name-claude", "Claude Code")
    assert has_element?(view, "#backend-name-agy", "Antigravity CLI")
  end

  test "saves an executable path and models, then renders them back", %{conn: conn} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_backends_live_4",
        login: "backends_live_user_4",
        email: "backends_live_user_4@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)

    assert {:ok, view, _html} = live(authed_conn, ~p"/settings/backends")

    view |> element("#add-model-claude") |> render_click()
    assert has_element?(view, "#model-row-claude-0")

    view
    |> element("#backend-form-claude")
    |> render_submit(%{
      "backend" => "claude",
      "executable_path" => "  /usr/local/bin/claude  ",
      "models" => %{"0" => %{"id" => "claude-opus-5", "display_name" => "Opus 5"}}
    })

    assert has_element?(view, "#saved-claude", "Saved")

    assert %{
             executable_path: "/usr/local/bin/claude",
             models: [%{id: "claude-opus-5", display_name: "Opus 5"}]
           } = Backends.get_backend(:claude)

    # The saved values are rendered back on reload
    assert {:ok, reloaded, html} = live(authed_conn, ~p"/settings/backends")
    assert html =~ "/usr/local/bin/claude"
    assert has_element?(reloaded, "#model-id-claude-0")
    refute has_element?(reloaded, "#no-models-claude")
  end

  test "an empty display name falls back to the model id", %{conn: conn} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_backends_live_5",
        login: "backends_live_user_5",
        email: "backends_live_user_5@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)

    assert {:ok, view, _html} = live(authed_conn, ~p"/settings/backends")

    view
    |> element("#backend-form-agy")
    |> render_submit(%{
      "backend" => "agy",
      "executable_path" => "/usr/local/bin/agy",
      "models" => %{"0" => %{"id" => "gemini-3.8-flash-high", "display_name" => ""}}
    })

    assert %{models: [%{display_name: "gemini-3.8-flash-high"}]} = Backends.get_backend(:agy)
  end

  test "updates an existing backend rather than inserting a second row", %{conn: conn} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_backends_live_6",
        login: "backends_live_user_6",
        email: "backends_live_user_6@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)

    {:ok, _backend} =
      Backends.create_backend(Scope.for_system(), %{
        name: :claude,
        executable_path: "/old/claude",
        models: [%{id: "old-model", display_name: "Old"}]
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/settings/backends")

    view
    |> element("#backend-form-claude")
    |> render_submit(%{
      "backend" => "claude",
      "executable_path" => "/new/claude",
      "models" => %{"0" => %{"id" => "new-model", "display_name" => "New"}}
    })

    assert %{executable_path: "/new/claude", models: [%{id: "new-model"}]} =
             Backends.get_backend(:claude)

    assert length(Backends.list_backends()) == 1
  end

  test "removing a model row drops it from the saved models", %{conn: conn} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_backends_live_7",
        login: "backends_live_user_7",
        email: "backends_live_user_7@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)

    {:ok, _backend} =
      Backends.create_backend(Scope.for_system(), %{
        name: :claude,
        executable_path: "/usr/local/bin/claude",
        models: [%{id: "keep-me", display_name: "Keep"}, %{id: "drop-me", display_name: "Drop"}]
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/settings/backends")

    view |> element("#remove-model-claude-1") |> render_click()
    refute has_element?(view, "#model-row-claude-1")

    view
    |> element("#backend-form-claude")
    |> render_submit(%{
      "backend" => "claude",
      "executable_path" => "/usr/local/bin/claude",
      "models" => %{"0" => %{"id" => "keep-me", "display_name" => "Keep"}}
    })

    assert %{models: [%{id: "keep-me"}]} = Backends.get_backend(:claude)
  end

  test "surfaces a validation error when the executable path is blank", %{conn: conn} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_backends_live_8",
        login: "backends_live_user_8",
        email: "backends_live_user_8@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)

    assert {:ok, view, _html} = live(authed_conn, ~p"/settings/backends")

    view
    |> element("#backend-form-claude")
    |> render_submit(%{"backend" => "claude", "executable_path" => "", "models" => %{}})

    assert has_element?(view, "#backends-save-error", "executable_path")
    assert is_nil(Backends.get_backend(:claude))
  end

  test "renders account status, quota windows, and banners", %{conn: conn} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_backends_live_9",
        login: "backends_live_user_9",
        email: "backends_live_user_9@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)
    now = DateTime.utc_now()
    reset_today = DateTime.to_iso8601(DateTime.shift(now, minute: 30))
    reset_tomorrow = DateTime.to_iso8601(DateTime.shift(now, day: 1))
    node = CliAccount.default_node()

    Repo.insert!(
      CliAccount.changeset(%CliAccount{}, %{
        node: node,
        backend: :claude,
        status: "ready",
        account_label: "alice@example.com",
        account_detail: "max",
        fetched_at: DateTime.shift(now, minute: -2),
        groups: [
          %{
            name: "Weekly Limits",
            count: 3,
            details: %{
              "windows" => [
                %{"label" => "Claude Sonnet", "remaining_percent" => 100.0, "resets_at" => reset_today},
                %{"label" => "Claude Haiku", "remaining_percent" => 25.5, "resets_at" => reset_tomorrow},
                %{
                  "label" => "Unmeasured Window",
                  "remaining_percent" => nil,
                  "resets_at" => nil,
                  "unmeasured_reason" => "Limit unmeasured"
                }
              ]
            }
          }
        ]
      })
    )

    Repo.insert!(
      CliAccount.changeset(%CliAccount{}, %{
        node: node,
        backend: :agy,
        status: "not_configured",
        unavailable_reason: "Executable not found at '/bin/agy'"
      })
    )

    assert {:ok, view, _html} = live(authed_conn, ~p"/settings/backends")

    assert has_element?(view, "#account-label-claude", "alice@example.com")
    assert has_element?(view, "#account-detail-claude", "MAX")
    assert has_element?(view, "#status-badge-claude", "Active")
    assert has_element?(view, "#fetched-at-claude", "read 2m ago")

    assert has_element?(view, "#group-name-claude-0", "Weekly Limits")
    assert has_element?(view, "#window-remaining-claude-0-0", "100% remaining")
    assert has_element?(view, "#window-reset-claude-0-0", "Resets today")
    assert has_element?(view, "#progress-bar-claude-0-0")
    assert has_element?(view, "#window-remaining-claude-0-1", "25.5% remaining")
    assert has_element?(view, "#window-reset-claude-0-1", "Resets tomorrow")
    assert has_element?(view, "#window-remaining-claude-0-2", "Limit unmeasured")
    assert has_element?(view, "#window-reset-claude-0-2", "Reset time unknown")
    refute has_element?(view, "#progress-bar-claude-0-2")

    assert has_element?(view, "#banner-agy", "Executable not found at '/bin/agy'")
  end

  test "renders signed_out, unavailable, and empty quota window states", %{conn: conn} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_backends_live_10",
        login: "backends_live_user_10",
        email: "backends_live_user_10@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)
    node = CliAccount.default_node()

    Repo.insert!(
      CliAccount.changeset(%CliAccount{}, %{
        node: node,
        backend: :claude,
        status: "signed_out",
        account_label: "signed_out@example.com",
        unavailable_reason: "CLI is signed out."
      })
    )

    Repo.insert!(
      CliAccount.changeset(%CliAccount{}, %{
        node: node,
        backend: :agy,
        status: "unavailable"
      })
    )

    assert {:ok, view, _html} = live(authed_conn, ~p"/settings/backends")

    assert has_element?(view, "#status-badge-claude", "Signed Out")
    assert has_element?(view, "#banner-claude", "CLI is signed out.")
    assert has_element?(view, "#status-badge-agy", "Unavailable")
    assert has_element?(view, "#banner-agy", "Failed to fetch usage data")

    ready = %CliAccount{id: "cli_ready", node: node, backend: :claude, status: "ready", groups: []}
    send(view.pid, {:usage_updated, [ready]})

    assert has_element?(view, "#no-quota-windows-claude", "No quota windows reported")
  end

  test "handles refresh_quotas, pubsub updates, ticks, and async failure", %{conn: conn} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_backends_live_11",
        login: "backends_live_user_11",
        email: "backends_live_user_11@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)
    now = DateTime.utc_now()
    node = CliAccount.default_node()

    expect(Backends, :refresh_usage, fn -> {:ok, []} end)

    assert {:ok, view, _html} = live(authed_conn, ~p"/settings/backends")

    view |> element("#refresh-quotas-button") |> render_click()
    # A second click while refreshing is a no-op
    render_click(element(view, "#refresh-quotas-button"))

    updated = %CliAccount{
      id: "cli_pubsub",
      node: node,
      backend: :claude,
      status: "ready",
      account_label: "pubsub@example.com",
      fetched_at: now,
      groups: [
        %CliAccountGroup{
          name: "Session Limits",
          count: 1,
          details: %{
            "windows" => [
              %{
                "label" => "Default Model",
                "remaining_percent" => 75.0,
                "resets_at" => DateTime.to_unix(DateTime.shift(now, hour: 1), :second)
              }
            ]
          }
        }
      ]
    }

    send(view.pid, {:usage_updated, [updated]})

    assert has_element?(view, "#account-label-claude", "pubsub@example.com")
    assert has_element?(view, "#window-remaining-claude-0-0", "75% remaining")
    assert has_element?(view, "#fetched-at-claude", "read just now")

    send(view.pid, :tick)
    assert has_element?(view, "#backends-settings")

    expect(Backends, :refresh_usage, fn -> {:error, :timeout} end)
    view |> element("#refresh-quotas-button") |> render_click()
    assert has_element?(view, "#refresh-quotas-button")
  end

  test "formats fetched ages and reset dates across units", %{conn: conn} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_backends_live_12",
        login: "backends_live_user_12",
        email: "backends_live_user_12@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)
    now = DateTime.utc_now()
    node = CliAccount.default_node()

    assert {:ok, view, _html} = live(authed_conn, ~p"/settings/backends")

    hours = %CliAccount{
      id: "cli_hours",
      node: node,
      backend: :claude,
      status: "ready",
      fetched_at: DateTime.shift(now, hour: -2),
      groups: []
    }

    days = %CliAccount{
      id: "cli_days",
      node: node,
      backend: :agy,
      status: "ready",
      fetched_at: DateTime.shift(now, day: -2),
      groups: []
    }

    send(view.pid, {:usage_updated, [hours, days]})

    assert has_element?(view, "#fetched-at-claude", "read 2h ago")
    assert has_element?(view, "#fetched-at-agy", "read 2d ago")

    formats = %CliAccount{
      id: "cli_formats",
      node: node,
      backend: :claude,
      status: "ready",
      fetched_at: now,
      groups: [
        %CliAccountGroup{
          name: "Limits",
          count: 4,
          details: %{
            "windows" => [
              %{
                "label" => "Unix MS",
                "remaining_percent" => 50.0,
                "resets_at" => DateTime.to_unix(DateTime.shift(now, minute: 30), :millisecond)
              },
              %{"label" => "Float", "remaining_percent" => 45.0, "resets_at" => 1_700_000_000.5},
              %{"label" => "Naive String", "remaining_percent" => 5.0, "resets_at" => "2026-09-10 14:30:00"},
              %{"label" => "Invalid", "remaining_percent" => nil, "resets_at" => "invalid_date"}
            ]
          }
        },
        %CliAccountGroup{name: "No Windows", count: 0, details: %{}}
      ]
    }

    send(view.pid, {:usage_updated, [formats]})

    assert has_element?(view, "#window-reset-claude-0-0", "Resets today")
    assert has_element?(view, "#window-label-claude-0-1", "Float")
    assert has_element?(view, "#window-label-claude-0-2", "Naive String")
    assert has_element?(view, "#window-remaining-claude-0-3", "Limit unmeasured")
    assert has_element?(view, "#window-reset-claude-0-3", "Reset time unknown")
  end
end
