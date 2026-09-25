defmodule RailWeb.Settings.RolesLiveTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Projects
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Users
  alias Rail.Users.Schemas.User

  setup %{conn: conn} do
    id = System.unique_integer([:positive])

    assert {:ok, %User{} = admin_user} =
             Users.register_oauth_user(%{
               github_id: "admin_gh_#{id}",
               login: "admin_roles_#{id}",
               name: "Admin User #{id}",
               email: "admin_roles_#{id}@example.com",
               admin: true
             })

    {:ok, claude_backend} =
      Rail.Tools.create_backend(Rail.Scope.for_system(), %{
        name: :claude,
        label: "work",
        executable_path: "/usr/local/bin/claude",
        models: [%{id: "claude-sonnet-5", display_name: "claude-sonnet-5"}]
      })

    {:ok, agy_backend} =
      Rail.Tools.create_backend(Rail.Scope.for_system(), %{
        name: :agy,
        executable_path: "/usr/local/bin/agy"
      })

    admin_conn = log_in_user(conn, admin_user)

    assert {:ok, %User{} = regular_user} =
             Users.register_oauth_user(%{
               github_id: "reg_gh_#{id}",
               login: "reg_roles_#{id}",
               name: "Regular User #{id}",
               email: "reg_roles_#{id}@example.com",
               admin: false
             })

    regular_conn = log_in_user(conn, regular_user)

    %{
      conn: conn,
      admin_conn: admin_conn,
      admin_user: admin_user,
      regular_conn: regular_conn,
      claude_backend: claude_backend,
      agy_backend: agy_backend
    }
  end

  test "redirects an unauthenticated user to the sign-in page", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/settings/roles")
  end

  test "redirects non-admin user to /", %{regular_conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/settings/roles")
  end

  test "renders stage list and bound roles", %{claude_backend: claude_backend, admin_conn: conn, admin_user: admin_user} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Roles Live Project 13001",
        github_repo: "org/roles-live-13001",
        github_installation_id: 13_001,
        linear_team_key: "P13001",
        default_branch: "main",
        clone_path: "/tmp/repos/roles-live-13001",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    scope = Rail.Scope.for_user(admin_user)

    assert {:ok, %Role{id: _eng_id}} =
             Roles.create_role(scope, project, %{
               name: "Senior Engineer",
               description: "Writes tested features",
               stage: :engineer,
               backend_id: claude_backend.id,
               model: "claude-opus-5-5",
               reasoning_effort: :high,
               system_prompt: "You are an engineer."
             })

    assert {:ok, view, _html} = live(init_test_session(conn, %{selected_project_id: project.id}), ~p"/settings/roles")

    # Stage list checks
    assert has_element?(view, "#pipeline-stages-list")
    assert has_element?(view, "#stage-row-engineer")
    assert has_element?(view, "#bound-role-name-engineer", "Senior Engineer")
    assert has_element?(view, "#stage-row-product")
    assert has_element?(view, "#unbound-stage-notice-product", "No role bound")
    assert has_element?(view, "#assign-stage-button-product")
    refute has_element?(view, "#unbound-roles-section")

    # Change project via selector
    {:ok, project2} =
      Projects.create_project(system_scope(), %{
        name: "Secondary Project",
        github_repo: "org/roles-live-13002",
        github_installation_id: 13_002,
        linear_team_key: "P13002",
        default_branch: "main",
        clone_path: "/tmp/repos/roles-live-13002",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    view |> element("#project-selector-form") |> render_change(%{"project_id" => project2.id})
    assert_redirect(view, ~p"/project-selection?#{[project_id: project2.id, return_to: "/settings/roles"]}")
  end

  test "creates a new role with stage binding", %{agy_backend: agy_backend, admin_conn: conn} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Roles Live Project 13003",
        github_repo: "org/roles-live-13003",
        github_installation_id: 13_003,
        linear_team_key: "P13003",
        default_branch: "main",
        clone_path: "/tmp/repos/roles-live-13003",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    assert {:ok, view, _html} = live(init_test_session(conn, %{selected_project_id: project.id}), ~p"/settings/roles")

    # Open create modal for product stage
    view |> element("#assign-stage-button-product") |> render_click()
    assert has_element?(view, "#role-editor-modal")
    assert has_element?(view, "#role-modal-title", "New role")
    refute has_element?(view, "#role-identifier-card")

    # Two backends of one kind are told apart by their label.
    assert has_element?(view, "#role-backend-select option", "Claude Code (claude -p) · work")
    assert has_element?(view, "#role-backend-select option", "Antigravity (agy -p)")

    # Validate form change with backend change
    view
    |> element("#role-backend-select")
    |> render_change(%{"role" => %{"backend_id" => agy_backend.id}})

    view
    |> element("#role-form")
    |> render_change(%{
      "role" => %{
        "backend_id" => agy_backend.id,
        "model_choice" => "gemini-ultra-custom"
      }
    })

    # agy has no configured models, so the chosen model stays selectable on its own
    assert has_element?(view, "#role-model-select option[value='gemini-ultra-custom']")

    # Models are managed in backend settings
    assert has_element?(view, "#manage-models-link")

    # Form validation error on submit when prompt is empty
    view
    |> element("#role-form")
    |> render_submit(%{
      "role" => %{
        "name" => "Product Lead",
        "description" => "Owns specs",
        "stage" => "product",
        "backend_id" => agy_backend.id,
        "model_choice" => "gemini-3.8-flash-high",
        "reasoning_effort" => "medium",
        "system_prompt" => "",
        "max_concurrent" => "2"
      }
    })

    assert has_element?(view, "#role-prompt-error")

    # Submit valid form
    view
    |> element("#role-form")
    |> render_submit(%{
      "role" => %{
        "name" => "Product Lead",
        "description" => "Owns specs",
        "stage" => "product",
        "backend_id" => agy_backend.id,
        "model_choice" => "gemini-3.8-flash-high",
        "reasoning_effort" => "medium",
        "system_prompt" => "You are product lead.",
        "max_concurrent" => "2"
      }
    })

    refute has_element?(view, "#role-editor-modal")
    assert has_element?(view, "#bound-role-name-product", "Product Lead")
  end

  test "toolbar add button creates a role on the first free stage", %{claude_backend: claude_backend, admin_conn: conn} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Roles Live Project 13004",
        github_repo: "org/roles-live-13004",
        github_installation_id: 13_004,
        linear_team_key: "P13004",
        default_branch: "main",
        clone_path: "/tmp/repos/roles-live-13004",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    assert {:ok, view, _html} = live(init_test_session(conn, %{selected_project_id: project.id}), ~p"/settings/roles")

    # No stage param: defaults to the first canonical stage with no role bound
    view |> element("#add-custom-role-button") |> render_click()
    assert has_element?(view, "#role-editor-modal")
    assert has_element?(view, "#role-stage-select option[value='product'][selected]")

    view
    |> element("#role-form")
    |> render_submit(%{
      "role" => %{
        "name" => "Security Auditor",
        "description" => "Audits code",
        "stage" => "product",
        "backend_id" => claude_backend.id,
        "model_choice" => "claude-opus-5-5",
        "reasoning_effort" => "max",
        "system_prompt" => "You audit security.",
        "max_concurrent" => "1"
      }
    })

    refute has_element?(view, "#role-editor-modal")
    assert has_element?(view, "#bound-role-name-product", "Security Auditor")
  end

  test "edits an existing role", %{claude_backend: claude_backend, admin_conn: conn, admin_user: admin_user} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Roles Live Project 13005",
        github_repo: "org/roles-live-13005",
        github_installation_id: 13_005,
        linear_team_key: "P13005",
        default_branch: "main",
        clone_path: "/tmp/repos/roles-live-13005",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    scope = Rail.Scope.for_user(admin_user)

    assert {:ok, %Role{id: role_id}} =
             Roles.create_role(scope, project, %{
               name: "Bug Hunter",
               description: "Chases down defects",
               stage: :debugger,
               backend_id: claude_backend.id,
               model: "claude-opus-5-5",
               reasoning_effort: :high,
               system_prompt: "You chase down defects."
             })

    assert {:ok, view, _html} = live(init_test_session(conn, %{selected_project_id: project.id}), ~p"/settings/roles")

    view |> element("#edit-role-button-#{role_id}") |> render_click()
    assert has_element?(view, "#role-modal-title", "Bug Hunter")
    assert has_element?(view, "#role-stage-pill", "stage: debugger")
    assert has_element?(view, "#copy-role-identifier[data-copy-text='#{role_id}']")
    assert has_element?(view, "#role-unsaved-changes", "No unsaved changes")

    # Tabs switch panels, and each tab summarises what it holds.
    assert has_element?(view, "#role-tab-summary-configuration", "Identity · claude-opus-5-5 · high")
    assert has_element?(view, "#role-tab-summary-prompt", "23 chars")
    assert has_element?(view, "#role-tab-summary-mcp_tools", "None enabled")
    assert has_element?(view, "#role-panel-prompt.hidden")

    view |> element("#role-tab-prompt") |> render_click()
    refute has_element?(view, "#role-panel-prompt.hidden")
    assert has_element?(view, "#role-panel-configuration.hidden")

    view |> element("#role-prompt-preview-button") |> render_click()
    assert has_element?(view, "#role-prompt-preview", "You chase down defects.")
    assert has_element?(view, "#role-prompt-input.hidden")
    view |> element("#role-prompt-preview-button") |> render_click()
    refute has_element?(view, "#role-prompt-preview")

    # Edits are counted as unsaved changes until saved or discarded.
    view
    |> element("#role-form")
    |> render_change(%{"role" => %{"system_prompt" => "You chase down defects twice.", "reasoning_effort" => "low"}})

    assert has_element?(view, "#role-unsaved-changes", "2 unsaved changes · reasoning effort, prompt")

    view
    |> element("#role-form")
    |> render_change(%{"role" => %{"system_prompt" => "You chase down defects.", "reasoning_effort" => "high"}})

    assert has_element?(view, "#role-unsaved-changes", "No unsaved changes")

    view |> element("#role-form") |> render_change(%{"role" => %{"reasoning_effort" => "medium"}})
    assert has_element?(view, "#role-unsaved-changes", "1 unsaved change · reasoning effort")

    view |> element("#role-form") |> render_change(%{"role" => %{"name" => "  "}})
    assert has_element?(view, "#role-modal-title", "Untitled role")

    # A save that fails on the prompt alone opens the prompt tab.
    view |> element("#role-tab-configuration") |> render_click()

    view
    |> element("#role-form")
    |> render_submit(%{
      "role" => %{
        "name" => "Bug Hunter",
        "stage" => "debugger",
        "backend_id" => claude_backend.id,
        "model_choice" => "claude-opus-5-5",
        "system_prompt" => ""
      }
    })

    assert has_element?(view, "#role-prompt-error")
    refute has_element?(view, "#role-panel-prompt.hidden")

    # A stored model outside the backend's configured list stays selected
    assert has_element?(view, "#role-model-select option[value='claude-opus-5-5']")

    # Update description and prompt
    view
    |> element("#role-form")
    |> render_submit(%{
      "role" => %{
        "name" => "Chief Bug Hunter",
        "description" => "Leads the hunt",
        "stage" => "debugger",
        "backend_id" => claude_backend.id,
        "model_choice" => "claude-opus-5-5",
        "reasoning_effort" => "xhigh",
        "system_prompt" => "You are chief bug hunter.",
        "max_concurrent" => "1"
      }
    })

    refute has_element?(view, "#role-editor-modal")
    assert has_element?(view, "#bound-role-name-debugger", "Chief Bug Hunter")

    # Cancel modal button check
    view |> element("#edit-role-button-#{role_id}") |> render_click()
    assert has_element?(view, "#role-editor-modal")
    view |> element("#cancel-role-button") |> render_click()
    refute has_element?(view, "#role-editor-modal")
  end

  test "allows MCP tools on a role", %{claude_backend: claude_backend, admin_conn: conn, admin_user: admin_user} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Roles Live Project 13020",
        github_repo: "org/roles-live-13020",
        github_installation_id: 13_020,
        linear_team_key: "P13020",
        default_branch: "main",
        clone_path: "/tmp/repos/roles-live-13020"
      })

    {:ok, _linear} =
      Rail.Mcp.create_server(system_scope(), %{
        name: "rl_linear",
        url: "https://mcp.linear.app/mcp",
        tools: [%{"name" => "get_issue", "description" => "Reads an issue"}, %{"name" => "list_issues"}]
      })

    {:ok, _sentry} =
      Rail.Mcp.create_server(system_scope(), %{name: "rl_sentry", url: "https://mcp.sentry.dev/mcp"})

    assert {:ok, %Role{id: role_id}} =
             Roles.create_role(Rail.Scope.for_user(admin_user), project, %{
               name: "Engineer",
               stage: :engineer,
               backend_id: claude_backend.id,
               model: "claude-opus-5-5",
               system_prompt: "You are an engineer."
             })

    assert {:ok, view, _html} = live(init_test_session(conn, %{selected_project_id: project.id}), ~p"/settings/roles")

    view |> element("#edit-role-button-#{role_id}") |> render_click()
    assert has_element?(view, "#role-mcp-server-rl_sentry", "No tools cached yet")
    assert has_element?(view, "#role-mcp-summary-rl_linear", "No tools enabled")

    # Each server's tool list starts collapsed.
    assert has_element?(view, "#role-mcp-tools-rl_linear.hidden")
    view |> element("#role-mcp-toggle-rl_linear") |> render_click()
    refute has_element?(view, "#role-mcp-tools-rl_linear.hidden")
    assert has_element?(view, "#role-mcp-toggle-rl_linear", "Hide list")
    view |> element("#role-mcp-toggle-rl_linear") |> render_click()
    assert has_element?(view, "#role-mcp-tools-rl_linear.hidden")
    refute has_element?(view, "#role-mcp-tool-rl_linear__get_issue[checked]")
    refute has_element?(view, "#role-mcp-tool-rl_linear__get_issue[disabled]")

    # Checking a server's "all tools" checks and locks each of its tools.
    view |> element("#role-form") |> render_change(%{"role" => %{"mcp_tools" => ["", "rl_linear__get_issue"]}})
    assert has_element?(view, "#role-mcp-summary-rl_linear", "1 of 2 tools enabled")

    view |> element("#role-form") |> render_change(%{"role" => %{"mcp_tools" => ["", "rl_sentry__*"]}})
    assert has_element?(view, "#role-mcp-summary-rl_sentry", "all tools enabled")
    assert has_element?(view, "#role-tab-summary-mcp_tools", "rl_sentry · all")

    view |> element("#role-form") |> render_change(%{"role" => %{"mcp_tools" => ["", "rl_linear__*"]}})
    assert has_element?(view, "#role-mcp-tool-rl_linear__get_issue[checked][disabled]")
    assert has_element?(view, "#role-tab-summary-mcp_tools", "rl_linear · 2 of 2")

    view |> element("#role-form") |> render_change(%{"role" => %{"mcp_tools" => [""]}})
    refute has_element?(view, "#role-mcp-tool-rl_linear__get_issue[checked]")
    refute has_element?(view, "#role-mcp-tool-rl_linear__get_issue[disabled]")

    view
    |> element("#role-form")
    |> render_submit(%{
      "role" => %{
        "name" => "Engineer",
        "stage" => "engineer",
        "backend_id" => claude_backend.id,
        "model_choice" => "claude-opus-5-5",
        "reasoning_effort" => "high",
        "system_prompt" => "You are an engineer.",
        "max_concurrent" => "1",
        "mcp_tools" => ["", "rl_linear__get_issue", "rl_sentry__*", "rl_sentry__covered"]
      }
    })

    assert {:ok, %Role{mcp_tools: ["rl_linear__get_issue", "rl_sentry__*"]}} = Roles.get_role(id: role_id)

    view |> element("#edit-role-button-#{role_id}") |> render_click()
    assert has_element?(view, "#role-mcp-tool-rl_linear__get_issue[checked]")
    refute has_element?(view, "#role-mcp-tool-rl_linear__get_issue[disabled]")
    assert has_element?(view, "#role-mcp-all-rl_sentry[checked]")
  end

  test "deletes a role", %{claude_backend: claude_backend, admin_conn: conn, admin_user: admin_user} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Roles Live Project 13006",
        github_repo: "org/roles-live-13006",
        github_installation_id: 13_006,
        linear_team_key: "P13006",
        default_branch: "main",
        clone_path: "/tmp/repos/roles-live-13006",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    scope = Rail.Scope.for_user(admin_user)

    assert {:ok, %Role{id: role_id}} =
             Roles.create_role(scope, project, %{
               name: "Temporary Reviewer",
               stage: :review,
               backend_id: claude_backend.id,
               model: "claude-opus-5-5",
               system_prompt: "Review PRs"
             })

    assert {:ok, view, _html} = live(init_test_session(conn, %{selected_project_id: project.id}), ~p"/settings/roles")
    assert has_element?(view, "#delete-role-button-#{role_id}")

    # Open delete modal
    view |> element("#delete-role-button-#{role_id}") |> render_click()
    assert has_element?(view, "#delete-role-modal")
    assert has_element?(view, "#delete-role-name", "Temporary Reviewer")

    # Cancel delete
    view |> element("#cancel-delete-button") |> render_click()
    refute has_element?(view, "#delete-role-modal")
    assert has_element?(view, "#delete-role-button-#{role_id}")

    # Confirm delete
    view |> element("#delete-role-button-#{role_id}") |> render_click()
    view |> element("#confirm-delete-button") |> render_click()
    refute has_element?(view, "#delete-role-modal")
    refute has_element?(view, "#bound-role-name-review")
  end

  test "copies roles from another project", %{agy_backend: agy_backend, admin_conn: conn, admin_user: admin_user} do
    scope = Rail.Scope.for_user(admin_user)

    {:ok, source_project} =
      Projects.create_project(system_scope(), %{
        name: "Source Project",
        github_repo: "org/roles-live-13007",
        github_installation_id: 13_007,
        linear_team_key: "P13007",
        default_branch: "main",
        clone_path: "/tmp/repos/roles-live-13007",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    assert {:ok, %Role{}} =
             Roles.create_role(scope, source_project, %{
               name: "Demo Recorder Role",
               stage: :demo,
               backend_id: agy_backend.id,
               model: "gemini-3.8-flash-high",
               system_prompt: "Record demos"
             })

    {:ok, target_project} =
      Projects.create_project(system_scope(), %{
        name: "Target Project",
        github_repo: "org/roles-live-13008",
        github_installation_id: 13_008,
        linear_team_key: "P13008",
        default_branch: "main",
        clone_path: "/tmp/repos/roles-live-13008",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    assert {:ok, view, _html} =
             live(init_test_session(conn, %{selected_project_id: target_project.id}), ~p"/settings/roles")

    view |> element("#copy-roles-button") |> render_click()
    assert has_element?(view, "#copy-roles-modal")

    view
    |> element("#copy-roles-form")
    |> render_submit(%{"source_project_id" => source_project.id, "replace_all" => "false"})

    refute has_element?(view, "#copy-roles-modal")
    assert has_element?(view, "#bound-role-name-demo", "Demo Recorder Role")
  end

  test "auto-selects active project when no query param provided, and handles patch without project", %{
    admin_conn: conn,
    admin_user: _admin_user
  } do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Roles Live Project 13012",
        github_repo: "org/roles-live-13012",
        github_installation_id: 13_012,
        linear_team_key: "P13012",
        default_branch: "main",
        clone_path: "/tmp/repos/roles-live-13012",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        },
        active: true
      })

    assert {:ok, view, _html} = live(conn, ~p"/settings/roles")
    assert has_element?(view, "#project-selector option[selected]", project.name)

    # Patch without project param when current_project_id is already set
    assert {:ok, view2, _html} = live(conn, ~p"/settings/roles")
    assert render(view2) =~ project.name
  end

  test "with no project selected the page edits the first active one and the switcher stays on All projects", %{
    admin_conn: conn
  } do
    {:ok, _inactive} =
      Projects.create_project(system_scope(), %{
        name: "Aaa Inactive 13021",
        github_repo: "org/roles-live-13021",
        github_installation_id: 13_021,
        linear_team_key: "P13021",
        default_branch: "main",
        clone_path: "/tmp/repos/roles-live-13021",
        linear_state_ids: %{"triage" => "st_triage"},
        active: false
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Roles Live Project 13020",
        github_repo: "org/roles-live-13020",
        github_installation_id: 13_020,
        linear_team_key: "P13020",
        default_branch: "main",
        clone_path: "/tmp/repos/roles-live-13020",
        linear_state_ids: %{"triage" => "st_triage"},
        active: true
      })

    assert {:ok, view, _html} = live(conn, ~p"/settings/roles")

    assert has_element?(view, "#project-selector option[selected]", project.name)
    assert has_element?(view, "#selected-project-name", "All projects")
    assert has_element?(view, "#nav-issues[href='/issues']")
  end

  test "select_project event updates selected project", %{
    admin_conn: conn,
    admin_user: _admin_user
  } do
    {:ok, project1} =
      Projects.create_project(system_scope(), %{
        name: "Project One",
        github_repo: "org/roles-live-13013",
        github_installation_id: 13_013,
        linear_team_key: "P13013",
        default_branch: "main",
        clone_path: "/tmp/repos/roles-live-13013",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    {:ok, project2} =
      Projects.create_project(system_scope(), %{
        name: "Project Two",
        github_repo: "org/roles-live-13014",
        github_installation_id: 13_014,
        linear_team_key: "P13014",
        default_branch: "main",
        clone_path: "/tmp/repos/roles-live-13014",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    assert {:ok, view, _html} = live(init_test_session(conn, %{selected_project_id: project1.id}), ~p"/settings/roles")
    assert has_element?(view, "#project-selector option[selected]", "Project One")

    view
    |> form("#project-selector-form", %{"project_id" => project2.id})
    |> render_change()

    assert_redirect(view, ~p"/project-selection?#{[project_id: project2.id, return_to: "/settings/roles"]}")
  end

  test "renders available models dropdown and validates name in create modal", %{
    agy_backend: agy_backend,
    claude_backend: claude_backend,
    admin_conn: conn,
    admin_user: _admin_user
  } do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Roles Live Project 13015",
        github_repo: "org/roles-live-13015",
        github_installation_id: 13_015,
        linear_team_key: "P13015",
        default_branch: "main",
        clone_path: "/tmp/repos/roles-live-13015",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    assert {:ok, view, _html} = live(init_test_session(conn, %{selected_project_id: project.id}), ~p"/settings/roles")

    # Open create modal from a stage row
    view |> element("#assign-stage-button-product") |> render_click()
    assert has_element?(view, "#role-editor-modal")

    # Options from available_models are rendered; the seeded backend has none, so pick ours
    render_hook(view, "change_backend", %{"role" => %{"backend_id" => claude_backend.id}})
    assert has_element?(view, "#role-model-select option[value='claude-sonnet-5']")

    refute has_element?(view, "#role-model-select option[value='__custom__']")

    # Submit the form with an empty name and an unparseable max_concurrent
    view
    |> form("#role-form", %{
      "role" => %{
        "name" => "",
        "description" => "A description",
        "stage" => "product",
        "backend_id" => claude_backend.id,
        "model_choice" => "claude-sonnet-5",
        "reasoning_effort" => "high",
        "system_prompt" => "Prompt",
        "max_concurrent" => "invalid"
      }
    })
    |> render_submit()

    assert has_element?(view, "#role-name-input-error", "can't be blank")

    # Validate with model_choice: nil
    render_hook(view, "validate_role", %{
      "role" => %{
        "backend_id" => claude_backend.id,
        "model_choice" => nil
      }
    })

    # Switching to a backend with no configured row yields no models
    render_hook(view, "change_backend", %{"role" => %{"backend_id" => agy_backend.id}})
    refute has_element?(view, "#role-model-select option[value='claude-sonnet-5']")
  end

  test "handles stage_default_name and max_concurrent variations in create modal", %{
    claude_backend: claude_backend,
    admin_conn: conn,
    admin_user: _admin_user
  } do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Roles Live Project 13016",
        github_repo: "org/roles-live-13016",
        github_installation_id: 13_016,
        linear_team_key: "P13016",
        default_branch: "main",
        clone_path: "/tmp/repos/roles-live-13016",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    assert {:ok, view, _html} = live(init_test_session(conn, %{selected_project_id: project.id}), ~p"/settings/roles")

    # Open with atom/string stage that exists in default role names
    render_hook(view, "open_create_modal", %{"stage" => "engineer"})
    assert has_element?(view, "#role-editor-modal")
    assert has_element?(view, "input[name='role[name]'][value='Engineer']")

    # Open with unknown stage string
    render_hook(view, "open_create_modal", %{"stage" => "unknown_custom_stage_test"})
    assert has_element?(view, "input[name='role[name]'][value='Unknown_custom_stage_test']")

    # Submit with integer max_concurrent
    render_hook(view, "change_backend", %{"role" => %{"backend_id" => claude_backend.id}})

    view
    |> form("#role-form", %{
      "role" => %{
        "name" => "Valid Name",
        "description" => "Desc",
        "stage" => "engineer",
        "backend_id" => claude_backend.id,
        "model_choice" => "claude-sonnet-5",
        "reasoning_effort" => "high",
        "system_prompt" => "Prompt",
        "max_concurrent" => 3
      }
    })
    |> render_submit()

    refute has_element?(view, "#role-editor-modal")

    # Create another with max_concurrent: nil
    render_hook(view, "open_create_modal", %{"stage" => ""})
    assert has_element?(view, "#role-editor-modal")
    render_hook(view, "change_backend", %{"role" => %{"backend_id" => claude_backend.id}})

    view
    |> form("#role-form", %{
      "role" => %{
        "name" => "Another Valid Name",
        "description" => "Desc",
        "stage" => "qa",
        "backend_id" => claude_backend.id,
        "model_choice" => "claude-sonnet-5",
        "reasoning_effort" => "high",
        "system_prompt" => "Prompt",
        "max_concurrent" => ""
      }
    })
    |> render_submit()

    refute has_element?(view, "#role-editor-modal")
  end

  test "handles unconfigured backends, blank model and stage, and unrelated messages", %{
    claude_backend: claude_backend,
    admin_conn: conn
  } do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Roles Live Project 13021",
        github_repo: "org/roles-live-13021",
        github_installation_id: 13_021,
        linear_team_key: "P13021",
        default_branch: "main",
        clone_path: "/tmp/repos/roles-live-13021"
      })

    {:ok, _codex_backend} =
      Rail.Tools.create_backend(Rail.Scope.for_system(), %{name: :codex, executable_path: "/usr/local/bin/codex"})

    assert {:ok, view, _html} = live(init_test_session(conn, %{selected_project_id: project.id}), ~p"/settings/roles")

    send(view.pid, :unrelated_pipeline_event)

    view |> element("#assign-stage-button-product") |> render_click()
    assert has_element?(view, "#role-backend-select option", "codex")

    render_hook(view, "validate_role", %{
      "role" => %{"backend_id" => claude_backend.id, "model_choice" => "claude-sonnet-5"}
    })

    assert has_element?(view, "#role-model-select option[value='claude-sonnet-5'][selected]")

    render_hook(view, "change_backend", %{"role" => %{"backend_id" => ""}})
    refute has_element?(view, "#role-model-select option")

    view
    |> element("#role-form")
    |> render_submit(%{
      "role" => %{
        "name" => "No Model",
        "stage" => "",
        "backend_id" => claude_backend.id,
        "model_choice" => "",
        "system_prompt" => "Prompt"
      }
    })

    assert has_element?(view, "#role-model-select-error", "can't be blank")
  end

  test "handles open_delete_modal with non-existent role and delete_role when modal_role is nil", %{
    admin_conn: conn,
    admin_user: _admin_user
  } do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Roles Live Project 13017",
        github_repo: "org/roles-live-13017",
        github_installation_id: 13_017,
        linear_team_key: "P13017",
        default_branch: "main",
        clone_path: "/tmp/repos/roles-live-13017",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    assert {:ok, view, _html} = live(init_test_session(conn, %{selected_project_id: project.id}), ~p"/settings/roles")

    render_hook(view, "open_delete_modal", %{"role_id" => "non_existent"})
    refute has_element?(view, "#delete-role-modal")

    render_hook(view, "delete_role", %{})
    refute has_element?(view, "#delete-role-modal")
  end

  test "handles copy modal edge cases", %{
    admin_conn: conn,
    admin_user: _admin_user
  } do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Roles Live Project 13018",
        github_repo: "org/roles-live-13018",
        github_installation_id: 13_018,
        linear_team_key: "P13018",
        default_branch: "main",
        clone_path: "/tmp/repos/roles-live-13018",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    {:ok, other_project} =
      Projects.create_project(system_scope(), %{
        name: "Roles Live Project 13019",
        github_repo: "org/roles-live-13019",
        github_installation_id: 13_019,
        linear_team_key: "P13019",
        default_branch: "main",
        clone_path: "/tmp/repos/roles-live-13019",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    assert {:ok, view, _html} = live(init_test_session(conn, %{selected_project_id: project.id}), ~p"/settings/roles")

    # Select project event via form change
    view
    |> form("#project-selector-form")
    |> render_change(%{"project_id" => other_project.id})

    assert_redirect(view, ~p"/project-selection?#{[project_id: other_project.id, return_to: "/settings/roles"]}")

    assert {:ok, view, _html} =
             live(init_test_session(conn, %{selected_project_id: other_project.id}), ~p"/settings/roles")

    # Validate copy event
    view |> element("#copy-roles-button") |> render_click()
    assert has_element?(view, "#copy-roles-modal")
    render_change(element(view, "#copy-roles-form"), %{"source_project_id" => project.id})

    # Trigger copy_roles error branch
    stub(Roles, :copy_roles, fn _scope, _target, _source, _opts -> {:error, :failed} end)
    render_hook(view, "copy_roles", %{"source_project_id" => project.id})
  end
end
