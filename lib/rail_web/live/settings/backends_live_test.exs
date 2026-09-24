defmodule RailWeb.Settings.BackendsLiveTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  # The backend lib/test_helper.exs seeds for the shared project's roles is the oldest, so
  # it heads every list as `_seeded`.

  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Tools
  alias Rail.Tools.Schemas.Backend
  alias Rail.Users

  test "redirects an unauthenticated user to the sign-in page", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/settings/backends")
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

  test "starts empty and adds an unsaved card per kind", %{conn: conn} do
    # The backend lib/test_helper.exs seeds would otherwise fill the empty page.
    stub(Tools, :list_backends, fn -> [] end)

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
    assert has_element?(view, "#no-backends")

    for name <- Backend.names(), do: assert(has_element?(view, "#add-backend-#{name}"))

    view |> element("#add-backend-claude") |> render_click()
    view |> element("#add-backend-agy") |> render_click()
    view |> element("#add-backend-codex") |> render_click()

    refute has_element?(view, "#no-backends")
    assert has_element?(view, "[id^='backend-name-new-']", "Claude Code")
    assert has_element?(view, "[id^='backend-name-new-']", "Antigravity CLI")
    assert has_element?(view, "[id^='backend-name-new-']", "Codex")
    assert has_element?(view, "[id^='account-label-new-']", "Not saved yet")
    refute has_element?(view, "[id^='status-badge-new-']")

    # A backend is signed in once it is saved, so a draft offers no sign-in.
    refute has_element?(view, "[id^='login-new-']")
  end

  test "saves a label, executable path and models, then renders them back", %{conn: conn} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_backends_live_4",
        login: "backends_live_user_4",
        email: "backends_live_user_4@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)

    assert {:ok, view, _html} = live(authed_conn, ~p"/settings/backends")

    view |> element("#add-backend-claude") |> render_click()
    view |> element("[id^='add-model-new-']") |> render_click()
    refute has_element?(view, "[id^='no-models-new-']")

    # An id is what makes a model; a row without one adds nothing.
    view |> element("[id^='confirm-add-model-new-']") |> render_click()
    refute has_element?(view, "[id^='model-row-new-']")

    view
    |> element("[id^='backend-form-new-']")
    |> render_change(%{"new_model" => %{"id" => " claude-opus-5 ", "display_name" => "Opus 5"}})

    view |> element("[id^='confirm-add-model-new-']") |> render_click()
    assert has_element?(view, "[id^='model-row-new-'][id$='-0']", "Opus 5")
    refute has_element?(view, "[id^='new-model-new-']")

    view
    |> element("[id^='backend-form-new-']")
    |> render_submit(%{
      "label" => " work ",
      "executable_path" => "  /usr/local/bin/claude  ",
      "models" => %{"0" => %{"id" => "claude-opus-5", "display_name" => "Opus 5"}}
    })

    assert [
             _seeded,
             %Backend{
               id: id,
               name: :claude,
               label: "work",
               executable_path: "/usr/local/bin/claude",
               models: [%{id: "claude-opus-5", display_name: "Opus 5"}]
             }
           ] = Tools.list_backends()

    assert has_element?(view, "#saved-#{id}", "Saved")
    refute has_element?(view, "[id^='backend-card-new-']")

    # The saved values are rendered back on reload
    assert {:ok, reloaded, _html} = live(authed_conn, ~p"/settings/backends")
    assert has_element?(reloaded, "#backend-label-#{id}", "work")

    # Saved backends start folded; their settings open from the header.
    refute has_element?(reloaded, "#backend-body-#{id}")
    reloaded |> element("#backend-header-#{id}") |> render_click()
    assert has_element?(reloaded, "#executable-path-#{id}[value='/usr/local/bin/claude']")
    assert has_element?(reloaded, "#model-id-#{id}-0")
    refute has_element?(reloaded, "#no-models-#{id}")
  end

  test "adds a second backend of a kind, told apart by its label", %{conn: conn} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_backends_live_13",
        login: "backends_live_user_13",
        email: "backends_live_user_13@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)

    {:ok, _default} = Tools.create_backend(Scope.for_system(), %{name: :claude, executable_path: "/bin/claude"})

    assert {:ok, view, _html} = live(authed_conn, ~p"/settings/backends")

    view |> element("#add-backend-claude") |> render_click()

    view
    |> element("[id^='backend-form-new-']")
    |> render_submit(%{"label" => "personal", "executable_path" => "/bin/claude", "models" => %{}})

    assert [_seeded, %Backend{label: nil}, %Backend{id: id, name: :claude, label: "personal"}] = Tools.list_backends()
    assert has_element?(view, "#backend-label-#{id}", "personal")
  end

  test "signs a Claude backend in from its card", %{conn: conn} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_backends_live_14",
        login: "backends_live_user_14",
        email: "backends_live_user_14@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)

    {:ok, backend} = Tools.create_backend(Scope.for_system(), %{name: :claude, executable_path: "/bin/claude"})
    {:ok, agy} = Tools.create_backend(Scope.for_system(), %{name: :agy, executable_path: "/bin/agy"})

    session = spawn(fn -> Process.sleep(:infinity) end)
    url = "https://claude.com/cai/oauth/authorize?code=true&state=abc"
    test_pid = self()

    expect(Tools, :start_backend_login, fn _scope, %Backend{id: id}, owner ->
      send(test_pid, {:owner, owner})
      ^id = backend.id
      {:ok, %{session: session, url: url}}
    end)

    assert {:ok, %{pid: view_pid} = view, _html} = live(authed_conn, ~p"/settings/backends")

    # Only a CLI Rail can sign in gets the controls.
    refute has_element?(view, "#login-#{agy.id}")

    view |> element("#start-login-#{backend.id}") |> render_click()
    render_async(view)

    # The session belongs to the page, so leaving it ends the sign-in.
    assert_received {:owner, ^view_pid}
    assert has_element?(view, "#login-url-#{backend.id}[href='#{url}']")

    # Signing in is followed by reading the account's usage, which is what the
    # card then shows.
    expect(Tools, :submit_backend_login_code, fn _scope, ^session, "the-code" -> :ok end)

    # The card says it is signing in only while the read is still running, so the
    # read waits here until the assertion below has seen it.
    expect(Tools, :refresh_usage, fn ->
      send(test_pid, {:reading_usage, self()})
      assert_receive :finish_reading

      {:ok, [Repo.update!(Backend.usage_changeset(backend, %{status: :ready, account_label: "me@example.com"}))]}
    end)

    view |> element("#login-code-form-#{backend.id}") |> render_change(%{"code" => "the-co"})
    assert has_element?(view, "#login-code-#{backend.id}[value='the-co']")

    view |> element("#login-code-form-#{backend.id}") |> render_submit(%{"code" => "the-code"})

    assert_receive {:reading_usage, reader}
    assert has_element?(view, "#submit-login-code-#{backend.id}", "Signing in")

    send(reader, :finish_reading)
    render_async(view)

    refute has_element?(view, "#login-code-form-#{backend.id}")
    assert has_element?(view, "#account-label-#{backend.id}", "me@example.com")
    assert has_element?(view, "#logout-#{backend.id}")
  end

  test "says why a sign-in failed, lets it be retried, and cancels it", %{conn: conn} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_backends_live_15",
        login: "backends_live_user_15",
        email: "backends_live_user_15@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)

    {:ok, backend} = Tools.create_backend(Scope.for_system(), %{name: :claude, executable_path: "/bin/claude"})

    assert {:ok, view, _html} = live(authed_conn, ~p"/settings/backends")

    failures = [
      {{:error, :expired}, "Sign-in expired"},
      {{:error, :login_exited}, "Sign-in ended before it finished"},
      {{:error, :not_authorized}, "not allowed"},
      {{:error, :timeout}, "Sign-in failed: :timeout"},
      {:raise, "Sign-in crashed"}
    ]

    for {result, message} <- failures do
      expect(Tools, :start_backend_login, fn _scope, _backend, _owner ->
        if result == :raise, do: raise("boom"), else: result
      end)

      view |> element("#start-login-#{backend.id}") |> render_click()
      render_async(view)

      assert has_element?(view, "#login-error-#{backend.id}", message)
    end

    session = spawn(fn -> Process.sleep(:infinity) end)

    stub(Tools, :start_backend_login, fn _scope, _backend, _owner ->
      {:ok, %{session: session, url: "https://claude.com/cai/oauth/authorize?x=1"}}
    end)

    view |> element("#start-login-#{backend.id}") |> render_click()
    render_async(view)
    refute has_element?(view, "#login-error-#{backend.id}")

    # A rejected code says so, and a fresh sign-in can be started.
    expect(Tools, :submit_backend_login_code, fn _scope, ^session, "bad" -> {:error, "Invalid code"} end)
    view |> element("#login-code-form-#{backend.id}") |> render_submit(%{"code" => "bad"})
    render_async(view)

    assert has_element?(view, "#login-error-#{backend.id}", "Sign-in failed: Invalid code")
    assert has_element?(view, "#start-login-#{backend.id}")

    view |> element("#start-login-#{backend.id}") |> render_click()
    render_async(view)

    expect(Tools, :cancel_backend_login, fn _scope, ^session -> :ok end)
    view |> element("#cancel-login-#{backend.id}") |> render_click()

    refute has_element?(view, "#login-code-form-#{backend.id}")
    assert has_element?(view, "#start-login-#{backend.id}")
  end

  test "signs a Claude backend out", %{conn: conn} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_backends_live_16",
        login: "backends_live_user_16",
        email: "backends_live_user_16@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)

    {:ok, backend} = Tools.create_backend(Scope.for_system(), %{name: :claude, executable_path: "/bin/claude"})
    backend = Repo.update!(Backend.usage_changeset(backend, %{status: :ready}))

    assert {:ok, view, _html} = live(authed_conn, ~p"/settings/backends")
    view |> element("#backend-header-#{backend.id}") |> render_click()

    expect(Tools, :logout_backend, fn _scope, %Backend{} -> {:error, "Not logged in"} end)
    view |> element("#logout-#{backend.id}") |> render_click()
    assert has_element?(view, "#login-error-#{backend.id}", "Not logged in")

    # The card changes as soon as the CLI signs out, without waiting on a refresh.
    expect(Tools, :logout_backend, fn _scope, %Backend{} ->
      {:ok, Repo.update!(Backend.usage_changeset(backend, %{status: :signed_out}))}
    end)

    view |> element("#logout-#{backend.id}") |> render_click()

    refute has_element?(view, "#login-error-#{backend.id}")
    assert has_element?(view, "#quotas-unavailable-#{backend.id}", "Quotas unavailable until sign-in")
    assert has_element?(view, "#account-label-#{backend.id}", "Not signed in")
    assert has_element?(view, "#start-login-#{backend.id}")
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

    view |> element("#add-backend-agy") |> render_click()

    view
    |> element("[id^='backend-form-new-']")
    |> render_submit(%{
      "executable_path" => "/usr/local/bin/agy",
      "models" => %{"0" => %{"id" => "gemini-3.8-flash-high", "display_name" => ""}}
    })

    assert [_seeded, %{name: :agy, models: [%{display_name: "gemini-3.8-flash-high"}]}] = Tools.list_backends()
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

    {:ok, backend} =
      Tools.create_backend(Scope.for_system(), %{
        name: :claude,
        executable_path: "/old/claude",
        models: [%{id: "old-model", display_name: "Old"}]
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/settings/backends")
    view |> element("#backend-header-#{backend.id}") |> render_click()

    view
    |> element("#backend-form-#{backend.id}")
    |> render_submit(%{
      "executable_path" => "/new/claude",
      "models" => %{"0" => %{"id" => "new-model", "display_name" => "New"}}
    })

    assert {:ok, %{executable_path: "/new/claude", models: [%{id: "new-model"}]}} =
             Tools.get_backend(backend.id)

    assert [_seeded, _updated] = Tools.list_backends()
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

    {:ok, backend} =
      Tools.create_backend(Scope.for_system(), %{
        name: :claude,
        executable_path: "/usr/local/bin/claude",
        models: [%{id: "keep-me", display_name: "Keep"}, %{id: "drop-me", display_name: "Drop"}]
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/settings/backends")
    view |> element("#backend-header-#{backend.id}") |> render_click()

    view |> element("#remove-model-#{backend.id}-1") |> render_click()
    refute has_element?(view, "#model-row-#{backend.id}-1")

    view
    |> element("#backend-form-#{backend.id}")
    |> render_submit(%{
      "executable_path" => "/usr/local/bin/claude",
      "models" => %{"0" => %{"id" => "keep-me", "display_name" => "Keep"}}
    })

    assert {:ok, %{models: [%{id: "keep-me"}]}} = Tools.get_backend(backend.id)
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

    view |> element("#add-backend-claude") |> render_click()

    view
    |> element("[id^='backend-form-new-']")
    |> render_submit(%{"executable_path" => "", "models" => %{}})

    assert has_element?(view, "#backends-save-error", "executable_path")
    assert [_seeded] = Tools.list_backends()
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
    # Anchored to the day rather than to an offset, so a run near midnight still
    # reads as today.
    reset_today = DateTime.to_iso8601(DateTime.new!(DateTime.to_date(now), ~T[23:00:00], "Etc/UTC"))

    reset_tomorrow =
      DateTime.to_iso8601(DateTime.new!(Date.add(DateTime.to_date(now), 1), ~T[09:00:00], "Etc/UTC"))

    claude =
      Repo.insert!(
        Backend.usage_changeset(%Backend{}, %{
          name: :claude,
          status: :ready,
          account_label: "alice@example.com",
          account_detail: "max",
          fetched_at: DateTime.shift(now, minute: -2),
          usage: [
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

    agy =
      Repo.insert!(
        Backend.usage_changeset(%Backend{}, %{
          name: :agy,
          status: :not_configured,
          unavailable_reason: "Executable not found at '/bin/agy'"
        })
      )

    assert {:ok, view, _html} = live(authed_conn, ~p"/settings/backends")

    assert has_element?(view, "#account-label-#{claude.id}", "alice@example.com")
    assert has_element?(view, "#account-detail-#{claude.id}", "max")
    assert has_element?(view, "#status-badge-#{claude.id}", "Active")
    assert has_element?(view, "#quotas-read-at", "quotas read 2m ago")

    assert has_element?(view, "#group-name-#{claude.id}-0", "Weekly Limits")
    assert has_element?(view, "#window-remaining-#{claude.id}-0-0", "100%")
    assert has_element?(view, "#window-reset-#{claude.id}-0-0", "resets today")
    assert has_element?(view, "#progress-bar-#{claude.id}-0-0")
    assert has_element?(view, "#window-remaining-#{claude.id}-0-1", "25.5%")
    assert has_element?(view, "#window-reset-#{claude.id}-0-1", "resets tomorrow")
    assert has_element?(view, "#window-remaining-#{claude.id}-0-2", "—")
    assert has_element?(view, "#window-reset-#{claude.id}-0-2", "reset time unknown")
    refute has_element?(view, "#progress-bar-#{claude.id}-0-2")

    # The wording the server renders is UTC; the instant is what lets the
    # client rewrite it on the viewer's own clock.
    assert [utc_instant] =
             view
             |> element("#window-reset-#{claude.id}-0-0")
             |> render()
             |> Floki.parse_fragment!()
             |> Floki.attribute("data-at")

    assert DateTime.from_iso8601(utc_instant) == DateTime.from_iso8601(reset_today)

    assert view
           |> element("#window-reset-#{claude.id}-0-2")
           |> render()
           |> Floki.parse_fragment!()
           |> Floki.attribute("data-at") == []

    assert has_element?(view, "#status-badge-#{agy.id}", "Not configured")
    view |> element("#backend-header-#{agy.id}") |> render_click()
    assert has_element?(view, "#banner-#{agy.id}", "Executable not found at '/bin/agy'")
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

    claude =
      Repo.insert!(
        Backend.usage_changeset(%Backend{}, %{
          name: :claude,
          status: :signed_out,
          account_label: "signed_out@example.com",
          unavailable_reason: "CLI is signed out."
        })
      )

    agy =
      Repo.insert!(
        Backend.usage_changeset(%Backend{}, %{
          name: :agy,
          status: :unavailable
        })
      )

    assert {:ok, view, _html} = live(authed_conn, ~p"/settings/backends")

    # Signed out is said in the header rather than as a badge or a banner.
    refute has_element?(view, "#status-badge-#{claude.id}")
    assert has_element?(view, "#quotas-unavailable-#{claude.id}")
    view |> element("#backend-header-#{claude.id}") |> render_click()
    refute has_element?(view, "#banner-#{claude.id}")

    assert has_element?(view, "#status-badge-#{agy.id}", "Unavailable")
    view |> element("#backend-header-#{agy.id}") |> render_click()
    assert has_element?(view, "#banner-#{agy.id}", "Failed to fetch usage data")

    # Folding a card hides its settings again.
    view |> element("#backend-header-#{agy.id}") |> render_click()
    refute has_element?(view, "#backend-body-#{agy.id}")

    # The view re-reads after a refresh, so the probe result is what lands in the row.
    Repo.update!(Backend.usage_changeset(claude, %{status: :ready, usage: []}))
    expect(Tools, :refresh_usage, fn -> {:ok, []} end)
    view |> element("#refresh-quotas-button") |> render_click()

    assert has_element?(view, "#no-quota-windows-#{claude.id}", "No quota windows reported")
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
    stub(Tools, :refresh_usage, fn -> {:ok, []} end)

    assert {:ok, view, _html} = live(authed_conn, ~p"/settings/backends")

    view |> element("#refresh-quotas-button") |> render_click()
    render_click(element(view, "#refresh-quotas-button"))

    claude =
      Repo.insert!(
        Backend.usage_changeset(%Backend{}, %{
          name: :claude,
          status: :ready,
          account_label: "pubsub@example.com",
          fetched_at: now,
          usage: [
            %{
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
        })
      )

    # Refreshing is what pulls new usage; the tick only moves the clock.
    expect(Tools, :refresh_usage, fn -> {:ok, []} end)
    view |> element("#refresh-quotas-button") |> render_click()

    assert has_element?(view, "#account-label-#{claude.id}", "pubsub@example.com")
    assert has_element?(view, "#window-remaining-#{claude.id}-0-0", "75%")
    assert has_element?(view, "#quotas-read-at", "quotas read just now")

    send(view.pid, :tick)
    assert has_element?(view, "#backends-settings")

    expect(Tools, :refresh_usage, fn -> {:error, :timeout} end)
    view |> element("#refresh-quotas-button") |> render_click()
    assert has_element?(view, "#refresh-quotas-button")
  end

  test "keeps drafts on change, surfaces authorization failures, and ignores unrelated messages", %{conn: conn} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_backends_live_13",
        login: "backends_live_user_13",
        email: "backends_live_user_13@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)

    codex = Repo.insert!(Backend.usage_changeset(%Backend{}, %{name: :codex, status: :signed_out}))
    {:ok, claude} = Tools.create_backend(Scope.for_system(), %{name: :claude, executable_path: "/bin/claude"})

    assert {:ok, view, _html} = live(authed_conn, ~p"/settings/backends")

    send(view.pid, :unrelated_pipeline_event)
    assert has_element?(view, "#quotas-unavailable-#{codex.id}")

    # Only Claude Code can be signed in from here.
    refute has_element?(view, "#start-login-#{codex.id}")

    view |> element("#backend-header-#{claude.id}") |> render_click()

    view
    |> element("#backend-form-#{claude.id}")
    |> render_change(%{
      "executable_path" => "/draft/claude",
      "models" => %{"0" => %{"id" => "draft-model"}}
    })

    assert has_element?(view, "#executable-path-#{claude.id}[value='/draft/claude']")
    assert has_element?(view, "#model-id-#{claude.id}-0[value='draft-model']")

    expect(Tools, :update_backend, fn _scope, _backend, _attrs -> {:error, :not_authorized} end)

    view
    |> element("#backend-form-#{claude.id}")
    |> render_submit(%{"executable_path" => "/usr/local/bin/claude"})

    assert has_element?(view, "#backends-save-error", "You are not allowed to change backend settings.")
  end

  test "renders unparseable reset times and groups without window details", %{conn: conn} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_backends_live_14",
        login: "backends_live_user_14",
        email: "backends_live_user_14@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)

    claude =
      Repo.insert!(
        Backend.usage_changeset(%Backend{}, %{
          name: :claude,
          status: :ready,
          usage: [
            %{
              name: "Limits",
              details: %{
                "windows" => [
                  %{"label" => "Out Of Range", "remaining_percent" => 50.0, "resets_at" => 100_000_000_000_000_000_000},
                  %{"label" => "Boolean", "remaining_percent" => 50.0, "resets_at" => true}
                ]
              }
            },
            %{name: "Nil Details", details: nil}
          ]
        })
      )

    assert {:ok, view, _html} = live(authed_conn, ~p"/settings/backends")

    assert has_element?(view, "#window-reset-#{claude.id}-0-0", "reset time unknown")
    assert has_element?(view, "#window-reset-#{claude.id}-0-1", "reset time unknown")
    assert has_element?(view, "#group-name-#{claude.id}-1", "Nil Details")
    refute has_element?(view, "#window-row-#{claude.id}-1-0")
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
    assert {:ok, view, _html} = live(authed_conn, ~p"/settings/backends")

    claude =
      Repo.insert!(
        Backend.usage_changeset(%Backend{}, %{
          name: :claude,
          status: :ready,
          fetched_at: DateTime.shift(now, hour: -2),
          usage: []
        })
      )

    agy =
      Repo.insert!(
        Backend.usage_changeset(%Backend{}, %{
          name: :agy,
          status: :ready,
          fetched_at: DateTime.shift(now, day: -2),
          usage: []
        })
      )

    expect(Tools, :refresh_usage, fn -> {:ok, []} end)
    view |> element("#refresh-quotas-button") |> render_click()

    # The most recent read is the one the page reports.
    assert has_element?(view, "#quotas-read-at", "quotas read 2h")
    refute has_element?(view, "#quotas-read-at", "2d")
    assert agy.fetched_at

    formats = %{
      status: :ready,
      fetched_at: now,
      usage: [
        %{
          name: "Limits",
          count: 4,
          details: %{
            "windows" => [
              %{
                "label" => "Unix MS",
                "remaining_percent" => 50.0,
                "resets_at" =>
                  DateTime.to_unix(DateTime.new!(DateTime.to_date(now), ~T[23:00:00], "Etc/UTC"), :millisecond)
              },
              %{"label" => "Float", "remaining_percent" => 45.0, "resets_at" => 1_700_000_000.5},
              %{"label" => "Naive String", "remaining_percent" => 5.0, "resets_at" => "2026-09-10 14:30:00"},
              %{"label" => "Invalid", "remaining_percent" => nil, "resets_at" => "invalid_date"}
            ]
          }
        },
        %{name: "No Windows", count: 0, details: %{}}
      ]
    }

    Repo.update!(Backend.usage_changeset(claude, formats))
    expect(Tools, :refresh_usage, fn -> {:ok, []} end)
    view |> element("#refresh-quotas-button") |> render_click()

    assert has_element?(view, "#window-reset-#{claude.id}-0-0", "resets today")
    assert has_element?(view, "#window-label-#{claude.id}-0-1", "Float")
    assert has_element?(view, "#window-label-#{claude.id}-0-2", "Naive String")
    assert has_element?(view, "#window-remaining-#{claude.id}-0-3", "—")
    assert has_element?(view, "#window-reset-#{claude.id}-0-3", "reset time unknown")
  end

  test "names a usage group only when its windows do not, and checks the executable path", %{conn: conn} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_backends_live_17",
        login: "backends_live_user_17",
        email: "backends_live_user_17@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)

    {:ok, claude} =
      Tools.create_backend(Scope.for_system(), %{
        name: :claude,
        executable_path: System.find_executable("sh"),
        models: [%{id: "claude-opus-5", display_name: "Opus 5"}]
      })

    claude =
      Repo.update!(
        Backend.usage_changeset(claude, %{
          status: :ready,
          account_label: "me@example.com",
          usage: [
            %{
              name: "Weekly",
              details: %{
                "windows" => [
                  %{"label" => "Weekly", "remaining_percent" => 92.0},
                  %{"label" => "Weekly · Fable", "remaining_percent" => 100.0}
                ]
              }
            },
            %{name: "Gemini Models", details: %{"windows" => [%{"label" => "5-hour", "remaining_percent" => 100.0}]}}
          ]
        })
      )

    assert {:ok, view, _html} = live(authed_conn, ~p"/settings/backends")

    assert has_element?(view, "#account-label-#{claude.id}", "me@example.com")
    refute has_element?(view, "#group-name-#{claude.id}-0")
    assert has_element?(view, "#group-name-#{claude.id}-1", "Gemini Models")

    view |> element("#backend-header-#{claude.id}") |> render_click()
    assert has_element?(view, "#executable-found-#{claude.id}", "found")

    view
    |> element("#backend-form-#{claude.id}")
    |> render_change(%{"label" => "work", "executable_path" => "/non/existent/claude"})

    assert has_element?(view, "#executable-found-#{claude.id}", "not found")

    view |> element("#remove-model-#{claude.id}-0") |> render_click()
    assert has_element?(view, "#no-models-#{claude.id}")

    # Discarding puts back what was saved.
    view |> element("#discard-backend-#{claude.id}") |> render_click()
    assert has_element?(view, "#executable-found-#{claude.id}", "✓ found")
    assert has_element?(view, "#model-row-#{claude.id}-0", "Opus 5")
    refute has_element?(view, "#backend-label-#{claude.id}")
  end

  test "discards a backend that was never saved", %{conn: conn} do
    # The backend lib/test_helper.exs seeds would otherwise fill the empty page.
    stub(Tools, :list_backends, fn -> [] end)

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_backends_live_18",
        login: "backends_live_user_18",
        email: "backends_live_user_18@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)

    assert {:ok, view, _html} = live(authed_conn, ~p"/settings/backends")

    assert has_element?(view, "#add-backend-button", "Add backend")
    view |> element("#add-backend-codex") |> render_click()
    assert has_element?(view, "[id^='backend-body-new-']")

    view |> element("[id^='discard-backend-new-']") |> render_click()
    refute has_element?(view, "[id^='backend-card-new-']")
    assert has_element?(view, "#no-backends")
  end

  test "offers sign-in for a backend whose CLI is in place but has no account yet", %{conn: conn} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_backends_live_19",
        login: "backends_live_user_19",
        email: "backends_live_user_19@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)

    {:ok, ready_cli} =
      Tools.create_backend(Scope.for_system(), %{name: :claude, executable_path: System.find_executable("sh")})

    {:ok, missing_cli} = Tools.create_backend(Scope.for_system(), %{name: :claude, executable_path: "/bin/claude"})

    assert {:ok, view, _html} = live(authed_conn, ~p"/settings/backends")

    assert has_element?(view, "#quotas-unavailable-#{ready_cli.id}", "Quotas unavailable until sign-in")
    assert has_element?(view, "#start-login-#{ready_cli.id}", "Sign in")
    refute has_element?(view, "#status-badge-#{ready_cli.id}")

    # A CLI that is not there is a configuration problem before it is a sign-in one.
    refute has_element?(view, "#quotas-unavailable-#{missing_cli.id}")
    assert has_element?(view, "#status-badge-#{missing_cli.id}", "Not configured")
  end

  test "finishes a sign-in the CLI completed through the browser it opened", %{conn: conn} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_backends_live_20",
        login: "backends_live_user_20",
        email: "backends_live_user_20@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)

    {:ok, backend} = Tools.create_backend(Scope.for_system(), %{name: :claude, executable_path: "/bin/claude"})
    session = spawn(fn -> Process.sleep(:infinity) end)

    stub(Tools, :start_backend_login, fn _scope, _backend, _owner ->
      {:ok, %{session: session, url: "https://claude.com/cai/oauth/authorize?x=1"}}
    end)

    assert {:ok, view, _html} = live(authed_conn, ~p"/settings/backends")

    view |> element("#start-login-#{backend.id}") |> render_click()
    render_async(view)

    # A session this page no longer holds is none of its business.
    send(view.pid, {:backend_login_exited, spawn(fn -> :ok end), :ok})
    assert has_element?(view, "#login-code-form-#{backend.id}")

    send(view.pid, {:backend_login_exited, session, {:error, "Login failed"}})
    assert has_element?(view, "#login-error-#{backend.id}", "Sign-in failed: Login failed")

    view |> element("#start-login-#{backend.id}") |> render_click()
    render_async(view)

    expect(Tools, :refresh_usage, fn ->
      {:ok, [Repo.update!(Backend.usage_changeset(backend, %{status: :ready, account_label: "me@example.com"}))]}
    end)

    send(view.pid, {:backend_login_exited, session, :ok})
    render_async(view)

    refute has_element?(view, "#login-#{backend.id}")
    assert has_element?(view, "#account-label-#{backend.id}", "me@example.com")
  end
end
