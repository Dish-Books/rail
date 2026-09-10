defmodule RailWeb.CliAccountsLiveTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Backends
  alias Rail.Backends.Schemas.CliAccount
  alias Rail.Domain.Embeds.CliAccountGroup
  alias Rail.Projects
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope

  test "redirects unauthenticated user to /auth/github", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/auth/github"}}} = live(conn, ~p"/cli-accounts")
  end

  test "renders CLI Accounts view and navigation rail with active CLI Accounts destination", %{
    conn: conn
  } do
    {authed_conn, _user} = log_in_test_user(conn)

    assert {:ok, view, _html} = live(authed_conn, ~p"/cli-accounts")

    assert has_element?(view, "#cli-accounts-view")
    assert has_element?(view, "#cli-accounts-title", "CLI Accounts")
    assert has_element?(view, "#refresh-quotas-button")

    # Nav rail checks
    assert has_element?(view, "#navigation-rail")
    assert has_element?(view, "#nav-overview[data-active='false']")
    assert has_element?(view, "#nav-issues[data-active='false']")
    assert has_element?(view, "#nav-cli-accounts[data-active='true']")
    assert has_element?(view, "#nav-settings[data-active='false']")

    # Top app bar checks
    assert has_element?(view, "#top-app-bar")
    assert has_element?(view, "#section-title", "CLI Accounts")
  end

  test "handles ?project=<id> param and updates project switcher", %{conn: conn} do
    {authed_conn, user} = log_in_test_user(conn)
    scope = Scope.for_user(user)

    assert {:ok, %Project{id: project_id, name: project_name}} =
             Projects.create_project(scope, %{
               name: "CLI Project",
               github_repo: "example/cli-project",
               github_installation_id: 602,
               linear_team_id: "t_cli",
               linear_team_key: "CLI",
               clone_path: "/tmp/cli-project",
               active: true
             })

    assert {:ok, view, _html} = live(authed_conn, ~p"/cli-accounts?project=#{project_id}")
    assert has_element?(view, "#selected-project-name", project_name)

    # Patch without project
    view |> element("#project-switcher-button") |> render_click()
    view |> element("#project-option-all") |> render_click()

    assert_patched(view, ~p"/cli-accounts")
    assert has_element?(view, "#selected-project-name", "All projects")
  end

  test "renders empty state when no accounts checked yet", %{conn: conn} do
    {authed_conn, _user} = log_in_test_user(conn)

    assert {:ok, view, _html} = live(authed_conn, ~p"/cli-accounts")
    assert has_element?(view, "#cli-accounts-empty")
    assert has_element?(view, "#cli-accounts-empty", "No CLI accounts checked yet. Click Refresh Quotas to probe.")
    refute has_element?(view, "#cli-accounts-list")
    refute has_element?(view, "#cli-accounts-loading")
  end

  test "renders populated backend accounts with active and not_configured statuses", %{conn: conn} do
    {authed_conn, _user} = log_in_test_user(conn)
    now = DateTime.utc_now()
    reset_today = DateTime.to_iso8601(DateTime.shift(now, minute: 30))
    reset_tomorrow = DateTime.to_iso8601(DateTime.shift(now, day: 1))
    reset_future = DateTime.to_iso8601(DateTime.shift(now, second: 500_000))

    node = CliAccount.default_node()

    _claude =
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
              count: 4,
              details: %{
                "windows" => [
                  %{
                    "label" => "Claude Sonnet",
                    "remaining_percent" => 100.0,
                    "resets_at" => reset_today
                  },
                  %{
                    "label" => "Claude Haiku",
                    "remaining_percent" => 25.5,
                    "resets_at" => reset_tomorrow
                  },
                  %{
                    "label" => "Claude Opus",
                    "remaining_percent" => 5.0,
                    "resets_at" => reset_future
                  },
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

    _agy =
      Repo.insert!(
        CliAccount.changeset(%CliAccount{}, %{
          node: node,
          backend: :agy,
          status: "not_configured",
          account_label: nil,
          account_detail: nil,
          fetched_at: nil,
          unavailable_reason: "Executable not found at '/bin/agy'"
        })
      )

    assert {:ok, view, _html} = live(authed_conn, ~p"/cli-accounts")

    refute has_element?(view, "#cli-accounts-empty")
    assert has_element?(view, "#cli-accounts-list")

    # Claude assertions
    assert has_element?(view, "#backend-card-claude")
    assert has_element?(view, "#backend-name-claude", "Claude Code")
    assert has_element?(view, "#account-label-claude", "alice@example.com")
    assert has_element?(view, "#account-detail-claude", "MAX")
    assert has_element?(view, "#status-badge-claude", "Active")
    assert has_element?(view, "#fetched-at-claude", "read 2m ago")

    # Group and window assertions
    assert has_element?(view, "#group-section-claude-0")
    assert has_element?(view, "#group-name-claude-0", "Weekly Limits")

    # Window 0: 100% remaining (green, resets today)
    assert has_element?(view, "#window-label-claude-0-0", "Claude Sonnet")
    assert has_element?(view, "#window-remaining-claude-0-0", "100% remaining")
    assert has_element?(view, "#window-reset-claude-0-0", "Resets today")
    assert has_element?(view, "#progress-bar-claude-0-0")

    # Window 1: 25.5% remaining (amber, resets tomorrow)
    assert has_element?(view, "#window-label-claude-0-1", "Claude Haiku")
    assert has_element?(view, "#window-remaining-claude-0-1", "25.5% remaining")
    assert has_element?(view, "#window-reset-claude-0-1", "Resets tomorrow")
    assert has_element?(view, "#progress-bar-claude-0-1")

    # Window 2: 5.0% remaining (red, resets future date)
    assert has_element?(view, "#window-label-claude-0-2", "Claude Opus")
    assert has_element?(view, "#window-remaining-claude-0-2", "5% remaining")
    assert has_element?(view, "#progress-bar-claude-0-2")

    # Window 3: Unmeasured (assert progress bar is strictly omitted per parity spec!)
    assert has_element?(view, "#window-label-claude-0-3", "Unmeasured Window")
    assert has_element?(view, "#window-remaining-claude-0-3", "Limit unmeasured")
    assert has_element?(view, "#window-reset-claude-0-3", "Reset time unknown")
    refute has_element?(view, "#progress-bar-claude-0-3")

    # AGY assertions
    assert has_element?(view, "#backend-card-agy")
    assert has_element?(view, "#backend-name-agy", "Antigravity CLI")
    assert has_element?(view, "#status-badge-agy", "Not Configured")
    assert has_element?(view, "#banner-not-configured-agy")
    assert has_element?(view, "#banner-not-configured-agy", "Executable not found at '/bin/agy'")
  end

  test "renders signed_out and unavailable banners and empty quota windows notice", %{conn: conn} do
    {authed_conn, _user} = log_in_test_user(conn)
    node = CliAccount.default_node()

    _signed_out_acc =
      Repo.insert!(
        CliAccount.changeset(%CliAccount{}, %{
          node: node,
          backend: :claude,
          status: "signed_out",
          account_label: "signed_out@example.com",
          account_detail: nil,
          unavailable_reason: "CLI is signed out."
        })
      )

    _unavailable_acc =
      Repo.insert!(
        CliAccount.changeset(%CliAccount{}, %{
          node: node,
          backend: :agy,
          status: "unavailable",
          account_label: nil,
          account_detail: nil,
          unavailable_reason: "Backend rate limited."
        })
      )

    assert {:ok, view, _html} = live(authed_conn, ~p"/cli-accounts")

    assert has_element?(view, "#banner-signed-out-claude")
    assert has_element?(view, "#banner-signed-out-claude", "CLI is signed out.")
    assert has_element?(view, "#status-badge-claude", "Signed Out")

    assert has_element?(view, "#banner-unavailable-agy")
    assert has_element?(view, "#banner-unavailable-agy", "Backend rate limited.")
    assert has_element?(view, "#status-badge-agy", "Unavailable")
  end

  test "renders ready status with empty groups notice", %{conn: conn} do
    {authed_conn, _user} = log_in_test_user(conn)
    node = CliAccount.default_node()

    _ready_no_groups =
      Repo.insert!(
        CliAccount.changeset(%CliAccount{}, %{
          node: node,
          backend: :claude,
          status: "ready",
          account_label: "bob@example.com",
          groups: []
        })
      )

    assert {:ok, view, _html} = live(authed_conn, ~p"/cli-accounts")
    assert has_element?(view, "#no-quota-windows-claude", "No quota windows reported for this account.")
  end

  test "handles refresh_quotas event, pubsub update, and 30s tick", %{conn: conn} do
    {authed_conn, _user} = log_in_test_user(conn)

    # Stub Backends.refresh_usage to avoid spawning real CLIs
    expect(Backends, :refresh_usage, fn ->
      {:ok, []}
    end)

    assert {:ok, view, _html} = live(authed_conn, ~p"/cli-accounts")

    # Click refresh quotas
    view |> element("#refresh-quotas-button") |> render_click()

    # Second click while refreshing is a no-op
    render_click(element(view, "#refresh-quotas-button"))

    # Send PubSub message with updated accounts
    now = DateTime.utc_now()
    node = CliAccount.default_node()

    updated_account = %CliAccount{
      id: "cli_test_pubsub",
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
                "resets_at" => DateTime.to_iso8601(DateTime.shift(now, hour: 1))
              }
            ]
          }
        }
      ]
    }

    send(view.pid, {:usage_updated, [updated_account]})

    assert has_element?(view, "#backend-card-claude")
    assert has_element?(view, "#account-label-claude", "pubsub@example.com")
    assert has_element?(view, "#window-remaining-claude-0-0", "75% remaining")

    # Send tick to update ages
    send(view.pid, :tick)
    assert has_element?(view, "#cli-accounts-view")
  end

  test "formats relative age for just now, minutes, hours, days, and nil fetched_at", %{conn: conn} do
    {authed_conn, _user} = log_in_test_user(conn)
    now = DateTime.utc_now()
    node = CliAccount.default_node()

    acc_just_now = %CliAccount{
      id: "cli_1",
      node: node,
      backend: :claude,
      status: "ready",
      account_label: "now@example.com",
      fetched_at: DateTime.shift(now, second: -20),
      groups: []
    }

    acc_hours = %CliAccount{
      id: "cli_2",
      node: node,
      backend: :agy,
      status: "ready",
      account_label: "hours@example.com",
      fetched_at: DateTime.shift(now, hour: -2),
      groups: []
    }

    assert {:ok, view, _html} = live(authed_conn, ~p"/cli-accounts")

    send(view.pid, {:usage_updated, [acc_just_now, acc_hours]})

    assert has_element?(view, "#fetched-at-claude", "read just now")
    assert has_element?(view, "#fetched-at-agy", "read 2h ago")

    # Update to days
    acc_days = %CliAccount{
      id: "cli_3",
      node: node,
      backend: :claude,
      status: "ready",
      account_label: "days@example.com",
      fetched_at: DateTime.shift(now, day: -2),
      groups: []
    }

    send(view.pid, {:usage_updated, [acc_days]})
    assert has_element?(view, "#fetched-at-claude", "read 2d ago")
  end

  test "handles various reset date formats including timestamps and naive datetimes", %{conn: conn} do
    {authed_conn, _user} = log_in_test_user(conn)
    now = DateTime.utc_now()
    node = CliAccount.default_node()
    unix_sec = DateTime.to_unix(DateTime.shift(now, minute: 30), :second)
    unix_ms = DateTime.to_unix(DateTime.shift(now, minute: 30), :millisecond)

    acc = %CliAccount{
      id: "cli_timestamps",
      node: node,
      backend: :claude,
      status: "ready",
      account_label: "ts@example.com",
      fetched_at: now,
      groups: [
        %CliAccountGroup{
          name: "Limits",
          count: 3,
          details: %{
            "windows" => [
              %{
                "label" => "Unix Sec",
                "remaining_percent" => 50.0,
                "resets_at" => unix_sec
              },
              %{
                "label" => "Unix MS",
                "remaining_percent" => 50.0,
                "resets_at" => unix_ms
              },
              %{
                "label" => "Naive String",
                "remaining_percent" => 50.0,
                "resets_at" => "2026-09-10 14:30:00"
              }
            ]
          }
        }
      ]
    }

    assert {:ok, view, _html} = live(authed_conn, ~p"/cli-accounts")
    send(view.pid, {:usage_updated, [acc]})

    assert has_element?(view, "#window-label-claude-0-0", "Unix Sec")
    assert has_element?(view, "#window-reset-claude-0-0", "Resets today")
    assert has_element?(view, "#window-label-claude-0-1", "Unix MS")
    assert has_element?(view, "#window-reset-claude-0-1", "Resets today")
    assert has_element?(view, "#window-label-claude-0-2", "Naive String")
  end

  test "renders fallback display name, icon, badge for unknown backend, and handles float reset time", %{
    conn: conn
  } do
    {authed_conn, _user} = log_in_test_user(conn)
    node = CliAccount.default_node()

    acc = %CliAccount{
      id: "cli_custom",
      node: node,
      backend: :custom_runner,
      status: "ready",
      account_label: "custom@example.com",
      fetched_at: nil,
      groups: [
        %CliAccountGroup{
          name: "Custom Limits",
          count: 2,
          details: %{
            "windows" => [
              %{
                "label" => "Float Reset",
                "remaining_percent" => 45.0,
                "resets_at" => 1_700_000_000.5
              },
              %{
                "label" => "Nil Reason Unmeasured",
                "remaining_percent" => nil,
                "resets_at" => "invalid_date",
                "unmeasured_reason" => nil
              }
            ]
          }
        },
        %CliAccountGroup{
          name: "Empty Windows Group",
          count: 0,
          details: %{}
        }
      ]
    }

    acc2 = %CliAccount{
      id: "cli_custom2",
      node: node,
      backend: :custom_runner2,
      status: "custom_status",
      account_label: nil,
      groups: []
    }

    assert {:ok, view, _html} = live(authed_conn, ~p"/cli-accounts")
    send(view.pid, {:usage_updated, [acc, acc2]})

    assert has_element?(view, "#backend-name-custom_runner", "Custom_runner")
    assert has_element?(view, "#status-badge-custom_runner2", "Custom_status")
    assert has_element?(view, "#window-label-custom_runner-0-0", "Float Reset")
    assert has_element?(view, "#window-label-custom_runner-0-1", "Nil Reason Unmeasured")
    assert has_element?(view, "#window-remaining-custom_runner-0-1", "Limit unmeasured")
    assert has_element?(view, "#window-reset-custom_runner-0-1", "Reset time unknown")

    # Send tick to update view
    send(view.pid, :tick)
    assert has_element?(view, "#cli-accounts-view")
  end

  test "handles refresh quotas async error and struct / atom datetime values", %{conn: conn} do
    {authed_conn, _user} = log_in_test_user(conn)
    now = DateTime.utc_now()
    node = CliAccount.default_node()

    expect(Backends, :refresh_usage, fn ->
      {:error, :timeout}
    end)

    assert {:ok, view, _html} = live(authed_conn, ~p"/cli-accounts")
    view |> element("#refresh-quotas-button") |> render_click()

    acc = %CliAccount{
      id: "cli_dt",
      node: node,
      backend: :claude,
      status: "ready",
      account_label: "dt@example.com",
      fetched_at: now,
      groups: [
        %CliAccountGroup{
          name: "DateTime Limits",
          count: 2,
          details: %{
            "windows" => [
              %{
                "label" => "Struct DT",
                "remaining_percent" => 50.0,
                "resets_at" => now
              },
              %{
                "label" => "Atom Reset",
                "remaining_percent" => 50.0,
                "resets_at" => :atom_reset
              },
              %{
                "label" => "Invalid Unix TS",
                "remaining_percent" => 50.0,
                "resets_at" => 100_000_000_000_000_000_000
              }
            ]
          }
        },
        %CliAccountGroup{
          name: "Nil Details",
          count: 0,
          details: nil
        }
      ]
    }

    send(view.pid, {:usage_updated, [acc]})
    assert has_element?(view, "#window-label-claude-0-0", "Struct DT")
    assert has_element?(view, "#window-reset-claude-0-1", "Reset time unknown")
  end
end
