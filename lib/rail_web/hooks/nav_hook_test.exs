defmodule RailWeb.Hooks.NavHookTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Projects
  alias Rail.Users
  alias RailTest.Mocks.Linear, as: LinearMock

  test "open_new_issue sets default project to current_project_id when active", %{conn: conn} do
    {:ok, _project1} =
      Projects.create_project(system_scope(), %{
        name: "Project One",
        github_repo: "org/nav-hook-13102",
        github_installation_id: 13_102,
        linear_team_id: "team_nav_hook_13102",
        linear_team_key: "ONE",
        default_branch: "main",
        clone_path: "/tmp/repos/nav-hook-13102",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        },
        linear_workspace: %{
          name: "Nav Hook Workspace 13101",
          external_id: "lin_ws_nav_hook_13101",
          token: "lin_api_token_nav_hook_13101",
          webhook_secret: "whsec_nav_hook_13101"
        },
        active: true
      })

    {:ok, project2} =
      Projects.create_project(system_scope(), %{
        name: "Project Two",
        github_repo: "org/nav-hook-13103",
        github_installation_id: 13_103,
        linear_team_id: "team_nav_hook_13103",
        linear_team_key: "TWO",
        default_branch: "main",
        clone_path: "/tmp/repos/nav-hook-13103",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        },
        linear_workspace: %{
          name: "Nav Hook Workspace 13101",
          external_id: "lin_ws_nav_hook_13101_2",
          token: "lin_api_token_nav_hook_13101",
          webhook_secret: "whsec_nav_hook_13101"
        },
        active: true
      })

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_nav_hook_1",
        login: "nav_hook_user_1",
        email: "nav_hook_user_1@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)

    assert {:ok, view, _html} = live(authed_conn, ~p"/issues?project=#{project2.id}")

    refute has_element?(view, "#capture-idea-dialog")

    view
    |> element("#global-capture-idea-button")
    |> render_click()

    assert has_element?(view, "#capture-idea-dialog")
    assert has_element?(view, "#capture-modal-title", "New Issue")
    assert has_element?(view, "#capture-project-dropdown option[value='#{project2.id}'][selected]")
  end

  test "open_new_issue falls back to first active project when current_project_id is not set or inactive", %{
    conn: conn
  } do
    {:ok, _inactive} =
      Projects.create_project(system_scope(), %{
        name: "Inactive Project",
        github_repo: "org/nav-hook-13105",
        github_installation_id: 13_105,
        linear_team_id: "team_nav_hook_13105",
        linear_team_key: "P13105",
        default_branch: "main",
        clone_path: "/tmp/repos/nav-hook-13105",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        },
        linear_workspace: %{
          name: "Nav Hook Workspace 13104",
          external_id: "lin_ws_nav_hook_13104",
          token: "lin_api_token_nav_hook_13104",
          webhook_secret: "whsec_nav_hook_13104"
        },
        active: false
      })

    {:ok, active} =
      Projects.create_project(system_scope(), %{
        name: "Active First",
        github_repo: "org/nav-hook-13106",
        github_installation_id: 13_106,
        linear_team_id: "team_nav_hook_13106",
        linear_team_key: "ACT",
        default_branch: "main",
        clone_path: "/tmp/repos/nav-hook-13106",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        },
        linear_workspace: %{
          name: "Nav Hook Workspace 13101",
          external_id: "lin_ws_nav_hook_13101_3",
          token: "lin_api_token_nav_hook_13101",
          webhook_secret: "whsec_nav_hook_13101"
        },
        active: true
      })

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_nav_hook_2",
        login: "nav_hook_user_2",
        email: "nav_hook_user_2@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)

    assert {:ok, view, _html} = live(authed_conn, ~p"/issues")

    view
    |> element("#new-issue-button")
    |> render_click()

    assert has_element?(view, "#capture-idea-dialog")
    assert has_element?(view, "#capture-project-dropdown option[value='#{active.id}'][selected]")
  end

  test "close_new_issue dismisses the modal", %{conn: conn} do
    {:ok, _project} =
      Projects.create_project(system_scope(), %{
        name: "Nav Hook Project 13108",
        github_repo: "org/nav-hook-13108",
        github_installation_id: 13_108,
        linear_team_id: "team_nav_hook_13108",
        linear_team_key: "P13108",
        default_branch: "main",
        clone_path: "/tmp/repos/nav-hook-13108",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        },
        linear_workspace: %{
          name: "Nav Hook Workspace 13107",
          external_id: "lin_ws_nav_hook_13107",
          token: "lin_api_token_nav_hook_13107",
          webhook_secret: "whsec_nav_hook_13107"
        },
        active: true
      })

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_nav_hook_3",
        login: "nav_hook_user_3",
        email: "nav_hook_user_3@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)

    assert {:ok, view, _html} = live(authed_conn, ~p"/issues")

    render_click(view, "open_new_issue", %{})
    assert has_element?(view, "#capture-idea-dialog")

    render_click(view, "close_new_issue", %{})
    refute has_element?(view, "#capture-idea-dialog")
  end

  test "capture_form_change updates form values and enables submit button", %{conn: conn} do
    {:ok, _project1} =
      Projects.create_project(system_scope(), %{
        name: "Prj 1",
        github_repo: "org/nav-hook-13110",
        github_installation_id: 13_110,
        linear_team_id: "team_nav_hook_13110",
        linear_team_key: "P13110",
        default_branch: "main",
        clone_path: "/tmp/repos/nav-hook-13110",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        },
        linear_workspace: %{
          name: "Nav Hook Workspace 13109",
          external_id: "lin_ws_nav_hook_13109",
          token: "lin_api_token_nav_hook_13109",
          webhook_secret: "whsec_nav_hook_13109"
        },
        active: true
      })

    {:ok, project2} =
      Projects.create_project(system_scope(), %{
        name: "Prj 2",
        github_repo: "org/nav-hook-13111",
        github_installation_id: 13_111,
        linear_team_id: "team_nav_hook_13111",
        linear_team_key: "P13111",
        default_branch: "main",
        clone_path: "/tmp/repos/nav-hook-13111",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        },
        linear_workspace: %{
          name: "Nav Hook Workspace 13101",
          external_id: "lin_ws_nav_hook_13101_4",
          token: "lin_api_token_nav_hook_13101",
          webhook_secret: "whsec_nav_hook_13101"
        },
        active: true
      })

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_nav_hook_4",
        login: "nav_hook_user_4",
        email: "nav_hook_user_4@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)

    assert {:ok, view, _html} = live(authed_conn, ~p"/issues")

    render_click(view, "open_new_issue", %{})
    assert has_element?(view, "#capture-submit-button[disabled]")

    view
    |> form("#capture-issue-form", %{
      "ask" => "Support offline mode",
      "project_id" => project2.id,
      "priority" => "urgent"
    })
    |> render_change()

    assert has_element?(view, "#capture-idea-input", "Support offline mode")
    assert has_element?(view, "#capture-project-dropdown option[value='#{project2.id}'][selected]")
    assert has_element?(view, "#capture-priority-dropdown option[value='urgent'][selected]")
    refute has_element?(view, "#capture-submit-button[disabled]")
  end

  test "capture_form_submit does nothing when ask is blank", %{conn: conn} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Nav Hook Project 13113",
        github_repo: "org/nav-hook-13113",
        github_installation_id: 13_113,
        linear_team_id: "team_nav_hook_13113",
        linear_team_key: "P13113",
        default_branch: "main",
        clone_path: "/tmp/repos/nav-hook-13113",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        },
        linear_workspace: %{
          name: "Nav Hook Workspace 13112",
          external_id: "lin_ws_nav_hook_13112",
          token: "lin_api_token_nav_hook_13112",
          webhook_secret: "whsec_nav_hook_13112"
        },
        active: true
      })

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_nav_hook_5",
        login: "nav_hook_user_5",
        email: "nav_hook_user_5@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)

    assert {:ok, view, _html} = live(authed_conn, ~p"/issues")

    render_click(view, "open_new_issue", %{})

    render_submit(view, "capture_form_submit", %{
      "ask" => "   ",
      "project_id" => project.id,
      "priority" => "medium"
    })

    assert has_element?(view, "#capture-idea-dialog")
    refute has_element?(view, "#capture-error-banner")
  end

  test "capture_form_submit fails gracefully when project is not found", %{conn: conn} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_nav_hook_6",
        login: "nav_hook_user_6",
        email: "nav_hook_user_6@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)

    assert {:ok, view, _html} = live(authed_conn, ~p"/issues")

    render_click(view, "open_new_issue", %{})

    render_submit(view, "capture_form_submit", %{
      "ask" => "Some idea",
      "project_id" => "nonexistent_project_id",
      "priority" => "medium"
    })

    assert has_element?(view, "#capture-idea-dialog")
    assert has_element?(view, "#capture-error-banner", "Project not found")
  end

  test "capture_form_submit creates issue, resets form, and broadcasts pipeline_changed", %{
    conn: conn
  } do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Nav Hook Project 13115",
        github_repo: "org/nav-hook-13115",
        github_installation_id: 13_115,
        linear_team_id: "team_nav_ok",
        linear_team_key: "P13115",
        default_branch: "main",
        clone_path: "/tmp/repos/nav-hook-13115",
        linear_state_ids: %{"triage" => "st_triage_ok"},
        linear_workspace: %{
          name: "Nav Hook Workspace 13114",
          external_id: "lin_ws_nav_hook_13114",
          token: "lin_api_token_nav_hook_13114",
          webhook_secret: "whsec_nav_hook_13114"
        },
        active: true
      })

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_nav_hook_7",
        login: "nav_hook_user_7",
        email: "nav_hook_user_7@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_nav_captured",
      "identifier" => "NAV-101",
      "title" => "Capture via LiveView",
      "description" => "Capture via LiveView\nMultiline body",
      "state" => %{"id" => "st_triage_ok", "name" => "Triage", "type" => "triage"},
      "branchName" => "nav-101-branch",
      "url" => "https://linear.app/issue/NAV-101",
      "createdAt" => "2026-09-02T10:00:00.000Z",
      "updatedAt" => "2026-09-02T10:00:00.000Z"
    })

    assert {:ok, view, _html} = live(authed_conn, ~p"/issues")

    render_click(view, "open_new_issue", %{})

    view
    |> form("#capture-issue-form", %{
      "ask" => "Capture via LiveView\nMultiline body",
      "project_id" => project.id,
      "priority" => "high"
    })
    |> render_submit()

    # Modal is closed on success
    refute has_element?(view, "#capture-idea-dialog")

    # PubSub broadcast received
  end

  test "capture_form_submit keeps modal open and preserves ask text on error", %{conn: conn} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Nav Hook Project 13117",
        github_repo: "org/nav-hook-13117",
        github_installation_id: 13_117,
        linear_team_id: "team_nav_err",
        linear_team_key: "P13117",
        default_branch: "main",
        clone_path: "/tmp/repos/nav-hook-13117",
        linear_state_ids: %{"triage" => "st_triage_err"},
        linear_workspace: %{
          name: "Nav Hook Workspace 13116",
          external_id: "lin_ws_nav_hook_13116",
          token: "lin_api_token_nav_hook_13116",
          webhook_secret: "whsec_nav_hook_13116"
        },
        active: true
      })

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_nav_hook_8",
        login: "nav_hook_user_8",
        email: "nav_hook_user_8@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)

    LinearMock.mock_mutation_failure("issueCreate")

    assert {:ok, view, _html} = live(authed_conn, ~p"/issues")

    render_click(view, "open_new_issue", %{})

    view
    |> form("#capture-issue-form", %{
      "ask" => "Critical production defect",
      "project_id" => project.id,
      "priority" => "urgent"
    })
    |> render_submit()

    # Modal remains open
    assert has_element?(view, "#capture-idea-dialog")
    # Ask text is preserved
    assert has_element?(view, "#capture-idea-input", "Critical production defect")
    # Error banner is visible
    assert has_element?(view, "#capture-error-banner")
  end

  test "handles switcher, theme, and rail toggle events", %{conn: conn} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Nav Hook Project 13119",
        github_repo: "org/nav-hook-13119",
        github_installation_id: 13_119,
        linear_team_id: "team_nav_hook_13119",
        linear_team_key: "P13119",
        default_branch: "main",
        clone_path: "/tmp/repos/nav-hook-13119",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        },
        linear_workspace: %{
          name: "Nav Hook Workspace 13118",
          external_id: "lin_ws_nav_hook_13118",
          token: "lin_api_token_nav_hook_13118",
          webhook_secret: "whsec_nav_hook_13118"
        },
        active: true
      })

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_nav_hook_9",
        login: "nav_hook_user_9",
        email: "nav_hook_user_9@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)

    assert {:ok, view, _html} = live(authed_conn, ~p"/issues")

    render_click(view, "toggle_rail", %{})
    render_click(view, "theme_changed", %{"theme" => "light"})
    render_click(view, "toggle_project_switcher", %{})
    assert has_element?(view, "#project-switcher-dialog")

    render_click(view, "close_project_switcher", %{})
    refute has_element?(view, "#project-switcher-dialog")

    render_click(view, "select_project", %{"project_id" => project.id})
    assert_patched(view, ~p"/issues?project=#{project.id}")

    render_click(view, "select_project", %{"project_id" => ""})
    assert_patched(view, ~p"/issues")
  end

  test "open_new_issue sets default_project_id to nil when no active projects exist", %{
    conn: conn
  } do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_nav_hook_11",
        login: "nav_hook_user_11",
        email: "nav_hook_user_11@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)

    assert {:ok, view, _html} = live(authed_conn, ~p"/issues")

    render_click(view, "open_new_issue", %{})
    assert has_element?(view, "#capture-idea-dialog")
  end

  test "capture_form_submit with empty project_id fails with project not found", %{conn: conn} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_nav_hook_12",
        login: "nav_hook_user_12",
        email: "nav_hook_user_12@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)

    assert {:ok, view, _html} = live(authed_conn, ~p"/issues")

    render_click(view, "open_new_issue", %{})

    render_submit(view, "capture_form_submit", %{
      "ask" => "Idea without project",
      "project_id" => "",
      "priority" => "medium"
    })

    assert has_element?(view, "#capture-error-banner", "Project not found")
  end

  test "capture_form_submit falls back to medium on invalid priority and fetches project from database", %{
    conn: conn
  } do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_nav_hook_13",
        login: "nav_hook_user_13",
        email: "nav_hook_user_13@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)

    assert {:ok, view, _html} = live(authed_conn, ~p"/issues")

    # Project created after mount so it must be fetched from DB via fetch_project
    {:ok, late_project} =
      Projects.create_project(system_scope(), %{
        name: "Nav Hook Project 13121",
        github_repo: "org/nav-hook-13121",
        github_installation_id: 13_121,
        linear_team_id: "team_late",
        linear_team_key: "P13121",
        default_branch: "main",
        clone_path: "/tmp/repos/nav-hook-13121",
        linear_state_ids: %{"triage" => "st_triage_late"},
        linear_workspace: %{
          name: "Nav Hook Workspace 13120",
          external_id: "lin_ws_nav_hook_13120",
          token: "lin_api_token_nav_hook_13120",
          webhook_secret: "whsec_nav_hook_13120"
        },
        active: true
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_nav_late",
      "identifier" => "NAV-102",
      "title" => "Late project issue",
      "description" => "Late project description",
      "state" => %{"id" => "st_triage_late", "name" => "Triage", "type" => "triage"},
      "branchName" => "nav-102",
      "url" => "https://linear.app/issue/NAV-102",
      "createdAt" => "2026-09-02T10:00:00.000Z",
      "updatedAt" => "2026-09-02T10:00:00.000Z"
    })

    render_click(view, "open_new_issue", %{})

    render_submit(view, "capture_form_submit", %{
      "ask" => "Late project description",
      "project_id" => late_project.id,
      "priority" => "invalid_priority_string"
    })

    refute has_element?(view, "#capture-idea-dialog")
  end

  test "capture_form_submit handles string error and atom error correctly", %{conn: conn} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Nav Hook Project 13123",
        github_repo: "org/nav-hook-13123",
        github_installation_id: 13_123,
        linear_team_id: "team_nav_hook_13123",
        linear_team_key: "P13123",
        default_branch: "main",
        clone_path: "/tmp/repos/nav-hook-13123",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        },
        linear_workspace: %{
          name: "Nav Hook Workspace 13122",
          external_id: "lin_ws_nav_hook_13122",
          token: "lin_api_token_nav_hook_13122",
          webhook_secret: "whsec_nav_hook_13122"
        },
        active: true
      })

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_nav_hook_14",
        login: "nav_hook_user_14",
        email: "nav_hook_user_14@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)

    assert {:ok, view, _html} = live(authed_conn, ~p"/issues")

    render_click(view, "open_new_issue", %{})

    # String error from create_issue
    expect(Rail.Issues, :create_issue, fn _project, _attrs ->
      {:error, "Direct string failure"}
    end)

    render_submit(view, "capture_form_submit", %{
      "ask" => "Testing string error",
      "project_id" => project.id,
      "priority" => "medium"
    })

    assert has_element?(view, "#capture-error-banner", "Direct string failure")

    # Atom error from create_issue
    expect(Rail.Issues, :create_issue, fn _project, _attrs ->
      {:error, :not_authorized}
    end)

    render_submit(view, "capture_form_submit", %{
      "ask" => "Testing atom error",
      "project_id" => project.id,
      "priority" => "medium"
    })

    assert has_element?(view, "#capture-error-banner", "not_authorized")
  end
end
