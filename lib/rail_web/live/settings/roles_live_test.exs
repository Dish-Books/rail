defmodule RailWeb.Settings.RolesLiveTest do
  use RailWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Rail.Roles
  alias Rail.Roles.RoleInstructionProposal
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

    {admin_conn, _logged_admin} = log_in_test_user(conn, admin_user)

    assert {:ok, %User{} = regular_user} =
             Users.register_oauth_user(%{
               github_id: "reg_gh_#{id}",
               login: "reg_roles_#{id}",
               name: "Regular User #{id}",
               email: "reg_roles_#{id}@example.com",
               admin: false
             })

    {regular_conn, _logged_regular} = log_in_test_user(conn, regular_user)

    %{
      conn: conn,
      admin_conn: admin_conn,
      admin_user: admin_user,
      regular_conn: regular_conn
    }
  end

  test "redirects unauthenticated user to /auth/github", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/auth/github"}}} = live(conn, ~p"/settings/roles")
  end

  test "redirects non-admin user to /", %{regular_conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/settings/roles")
  end

  test "renders empty state when no projects exist", %{admin_conn: conn} do
    assert {:ok, view, _html} = live(conn, ~p"/settings/roles")
    assert has_element?(view, "#roles-settings")
    assert has_element?(view, "#no-projects-message")
  end

  test "renders stage list, bound roles, and unbound roles", %{
    admin_conn: conn,
    admin_user: admin_user
  } do
    project = create_test_project()
    scope = Rail.Scope.for_user(admin_user)

    assert {:ok, %Role{id: _eng_id}} =
             Roles.create_role(scope, project.id, %{
               name: "Senior Engineer",
               description: "Writes tested features",
               stage: :engineer,
               cli_backend: :claude,
               model: "claude-3-7-sonnet",
               reasoning_effort: :high,
               system_prompt: "You are an engineer."
             })

    assert {:ok, %Role{id: custom_id}} =
             Roles.create_role(scope, project.id, %{
               name: "Documentation Specialist",
               description: "Writes technical docs",
               stage: nil,
               cli_backend: :agy,
               model: "gemini-3.8-flash-high",
               reasoning_effort: :low,
               system_prompt: "You write documentation."
             })

    assert {:ok, view, _html} = live(conn, ~p"/settings/roles?project=#{project.id}")

    # Stage list checks
    assert has_element?(view, "#pipeline-stages-list")
    assert has_element?(view, "#stage-row-engineer")
    assert has_element?(view, "#bound-role-name-engineer", "Senior Engineer")
    assert has_element?(view, "#stage-row-product")
    assert has_element?(view, "#unbound-stage-notice-product", "No role bound")
    assert has_element?(view, "#assign-stage-button-product")

    # Unbound section checks
    assert has_element?(view, "#unbound-roles-list")
    assert has_element?(view, "#role-name-#{custom_id}", "Documentation Specialist")

    # Change project via selector
    project2 = create_test_project(name: "Secondary Project")
    view |> element("#project-selector-form") |> render_change(%{"project_id" => project2.id})
    assert_patched(view, ~p"/settings/roles?project=#{project2.id}")
  end

  test "creates a new role with stage binding", %{
    admin_conn: conn
  } do
    project = create_test_project()
    assert {:ok, view, _html} = live(conn, ~p"/settings/roles?project=#{project.id}")

    # Open create modal for product stage
    view |> element("#assign-stage-button-product") |> render_click()
    assert has_element?(view, "#role-editor-modal")
    assert has_element?(view, "#role-modal-title", "Create New Role")

    # Validate form change with backend change and custom model
    view
    |> element("#role-backend-select")
    |> render_change(%{"role" => %{"cli_backend" => "agy"}})

    view
    |> element("#role-form")
    |> render_change(%{
      "role" => %{
        "cli_backend" => "agy",
        "model_choice" => "__custom__",
        "custom_model" => "gemini-ultra-custom"
      }
    })

    assert has_element?(view, "#custom-model-input-container")

    # Refresh models button
    view |> element("#refresh-models-button") |> render_click()

    # Form validation error on submit when prompt is empty
    view
    |> element("#role-form")
    |> render_submit(%{
      "role" => %{
        "name" => "Product Lead",
        "description" => "Owns specs",
        "stage" => "product",
        "cli_backend" => "agy",
        "model_choice" => "gemini-3.8-flash-high",
        "custom_model" => "",
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
        "cli_backend" => "agy",
        "model_choice" => "gemini-3.8-flash-high",
        "custom_model" => "",
        "reasoning_effort" => "medium",
        "system_prompt" => "You are product lead.",
        "max_concurrent" => "2"
      }
    })

    refute has_element?(view, "#role-editor-modal")
    assert has_element?(view, "#bound-role-name-product", "Product Lead")
  end

  test "creates an unbound custom role", %{
    admin_conn: conn
  } do
    project = create_test_project()
    assert {:ok, view, _html} = live(conn, ~p"/settings/roles?project=#{project.id}")

    view |> element("#add-custom-role-button") |> render_click()
    assert has_element?(view, "#role-editor-modal")

    view
    |> element("#role-form")
    |> render_submit(%{
      "role" => %{
        "name" => "Security Auditor",
        "description" => "Audits code",
        "stage" => "",
        "cli_backend" => "claude",
        "model_choice" => "claude-3-7-sonnet",
        "custom_model" => "",
        "reasoning_effort" => "max",
        "system_prompt" => "You audit security.",
        "max_concurrent" => "1"
      }
    })

    refute has_element?(view, "#role-editor-modal")
    assert has_element?(view, "#unbound-roles-section", "Security Auditor")
  end

  test "edits an existing role", %{
    admin_conn: conn,
    admin_user: admin_user
  } do
    project = create_test_project()
    scope = Rail.Scope.for_user(admin_user)

    assert {:ok, %Role{id: role_id}} =
             Roles.create_role(scope, project.id, %{
               name: "QA Lead",
               description: "Coordinates QA",
               stage: :qa_lead,
               cli_backend: :claude,
               model: "claude-3-7-sonnet",
               reasoning_effort: :high,
               system_prompt: "You verify quality."
             })

    assert {:ok, view, _html} = live(conn, ~p"/settings/roles?project=#{project.id}")

    view |> element("#edit-role-button-#{role_id}") |> render_click()
    assert has_element?(view, "#role-modal-title", "Edit Role: QA Lead")

    # Update description and prompt
    view
    |> element("#role-form")
    |> render_submit(%{
      "role" => %{
        "name" => "Chief Quality Officer",
        "description" => "Leads quality assurance",
        "stage" => "qa_lead",
        "cli_backend" => "claude",
        "model_choice" => "claude-3-7-sonnet",
        "custom_model" => "",
        "reasoning_effort" => "xhigh",
        "system_prompt" => "You are chief quality officer.",
        "max_concurrent" => "1"
      }
    })

    refute has_element?(view, "#role-editor-modal")
    assert has_element?(view, "#bound-role-name-qa_lead", "Chief Quality Officer")

    # Cancel modal button check
    view |> element("#edit-role-button-#{role_id}") |> render_click()
    assert has_element?(view, "#role-editor-modal")
    view |> element("#cancel-role-button") |> render_click()
    refute has_element?(view, "#role-editor-modal")
  end

  test "deletes a role", %{
    admin_conn: conn,
    admin_user: admin_user
  } do
    project = create_test_project()
    scope = Rail.Scope.for_user(admin_user)

    assert {:ok, %Role{id: role_id}} =
             Roles.create_role(scope, project.id, %{
               name: "Temporary Reviewer",
               stage: :review,
               cli_backend: :claude,
               model: "claude-3-7-sonnet",
               system_prompt: "Review PRs"
             })

    assert {:ok, view, _html} = live(conn, ~p"/settings/roles?project=#{project.id}")
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

  test "exports roles to JSON modal", %{
    admin_conn: conn,
    admin_user: admin_user
  } do
    project = create_test_project()
    scope = Rail.Scope.for_user(admin_user)

    assert {:ok, %Role{}} =
             Roles.create_role(scope, project.id, %{
               name: "Architect Role",
               stage: :architect,
               cli_backend: :claude,
               model: "claude-3-7-sonnet",
               system_prompt: "Design systems."
             })

    assert {:ok, view, _html} = live(conn, ~p"/settings/roles?project=#{project.id}")

    view |> element("#export-roles-button") |> render_click()
    assert has_element?(view, "#export-roles-modal")
    assert has_element?(view, "#export-roles-textarea")

    view |> element("#close-export-modal-button") |> render_click()
    refute has_element?(view, "#export-roles-modal")
  end

  test "imports roles from JSON modal", %{
    admin_conn: conn
  } do
    project = create_test_project()
    assert {:ok, view, _html} = live(conn, ~p"/settings/roles?project=#{project.id}")

    view |> element("#import-roles-button") |> render_click()
    assert has_element?(view, "#import-roles-modal")

    # Invalid JSON
    view
    |> element("#import-roles-form")
    |> render_submit(%{"import_json" => "{not valid json}"})

    assert has_element?(view, "#import-error-banner")

    # Valid JSON import
    valid_json =
      Jason.encode!([
        %{
          "name" => "Imported QA",
          "stage" => "qa",
          "cli_backend" => "agy",
          "model" => "gemini-3.8-flash-high",
          "system_prompt" => "QA tests",
          "reasoning_effort" => "medium"
        }
      ])

    view
    |> element("#import-roles-form")
    |> render_submit(%{"import_json" => valid_json, "replace_all" => "false"})

    refute has_element?(view, "#import-roles-modal")
    assert has_element?(view, "#bound-role-name-qa", "Imported QA")
  end

  test "copies roles from another project", %{
    admin_conn: conn,
    admin_user: admin_user
  } do
    scope = Rail.Scope.for_user(admin_user)
    source_project = create_test_project(name: "Source Project")

    assert {:ok, %Role{}} =
             Roles.create_role(scope, source_project.id, %{
               name: "Demo Recorder Role",
               stage: :demo,
               cli_backend: :agy,
               model: "gemini-3.8-flash-high",
               system_prompt: "Record demos"
             })

    target_project = create_test_project(name: "Target Project")
    assert {:ok, view, _html} = live(conn, ~p"/settings/roles?project=#{target_project.id}")

    view |> element("#copy-roles-button") |> render_click()
    assert has_element?(view, "#copy-roles-modal")

    view
    |> element("#copy-roles-form")
    |> render_submit(%{"source_project_id" => source_project.id, "replace_all" => "false"})

    refute has_element?(view, "#copy-roles-modal")
    assert has_element?(view, "#bound-role-name-demo", "Demo Recorder Role")
  end

  test "improve role flow with no finished runs shows empty evidence state", %{
    admin_conn: conn,
    admin_user: admin_user
  } do
    project = create_test_project()
    scope = Rail.Scope.for_user(admin_user)

    assert {:ok, %Role{id: role_id}} =
             Roles.create_role(scope, project.id, %{
               name: "Debugger Role",
               stage: :debugger,
               cli_backend: :claude,
               model: "claude-3-7-sonnet",
               system_prompt: "Debug errors"
             })

    assert {:ok, view, _html} = live(conn, ~p"/settings/roles?project=#{project.id}")

    view |> element("#improve-role-button-#{role_id}") |> render_click()
    assert has_element?(view, "#improve-role-modal")
    assert has_element?(view, "#no-runs-evidence-state")
    assert has_element?(view, "#no-runs-title", "No finished runs for this role yet")
    refute has_element?(view, "#start-improvement-button")

    view |> element("#improve-cancel-button") |> render_click()
    refute has_element?(view, "#improve-role-modal")
  end

  test "improve role flow full 3-step lifecycle to approval", %{
    admin_conn: conn,
    admin_user: admin_user
  } do
    project = create_test_project()
    scope = Rail.Scope.for_user(admin_user)

    assert {:ok, %Role{id: role_id}} =
             Roles.create_role(scope, project.id, %{
               name: "Engineer Role",
               stage: :engineer,
               cli_backend: :claude,
               model: "claude-3-7-sonnet",
               system_prompt: "Write code"
             })

    # Create a finished role run with output for evidence
    create_test_role_run(
      role_id: role_id,
      status: :finished,
      output: "Completed task implementation successfully."
    )

    assert {:ok, view, _html} = live(conn, ~p"/settings/roles?project=#{project.id}")

    # Open improve modal
    view |> element("#improve-role-button-#{role_id}") |> render_click()
    assert has_element?(view, "#improve-role-modal")
    assert has_element?(view, "#populated-runs-evidence-state")
    assert has_element?(view, "#evidence-found-text")
    assert has_element?(view, "#start-improvement-button")

    # Select improvement model
    view
    |> element("#improve-model-form")
    |> render_change(%{"improve_model" => "claude-3-7-sonnet"})

    # Start improvement -> transitions to running
    view |> element("#start-improvement-button") |> render_click()
    assert has_element?(view, "#improve-step-running")
    assert has_element?(view, "#running-analysis-message")

    # Simulate proposal completion message
    proposal = %RoleInstructionProposal{
      role_id: role_id,
      model_id: "claude-3-7-sonnet",
      current: "Write code",
      proposed: "Write clean, tested code",
      rationale: "Analysis shows past runs needed more test focus.",
      diff: "-Write code\n+Write clean, tested code",
      sources: [%{task_id: "tsk_1", title: "Past Task 1"}],
      usage: %{"input_tokens" => 500, "output_tokens" => 200}
    }

    send(view.pid, {make_ref(), {:ok, proposal}})

    # Transitions to proposal step
    assert has_element?(view, "#improve-step-proposal")
    assert has_element?(view, "#proposal-rationale-text", "Analysis shows past runs needed more test focus.")
    assert has_element?(view, "#instruction-diff-content")
    assert has_element?(view, "#approve-proposal-button")

    # Approve proposal -> updates role instructions
    view |> element("#approve-proposal-button") |> render_click()
    refute has_element?(view, "#improve-role-modal")

    updated_role = Roles.get_role!(scope, role_id)
    assert updated_role.system_prompt == "Write clean, tested code"
  end

  test "improve role handles run failure", %{
    admin_conn: conn,
    admin_user: admin_user
  } do
    project = create_test_project()
    scope = Rail.Scope.for_user(admin_user)

    assert {:ok, %Role{id: role_id}} =
             Roles.create_role(scope, project.id, %{
               name: "Test Role",
               stage: :rebase,
               cli_backend: :claude,
               model: "claude-3-7-sonnet",
               system_prompt: "Rebase branches"
             })

    create_test_role_run(role_id: role_id, status: :finished, output: "Output")

    assert {:ok, view, _html} = live(conn, ~p"/settings/roles?project=#{project.id}")

    view |> element("#improve-role-button-#{role_id}") |> render_click()
    view |> element("#start-improvement-button") |> render_click()

    # Send error
    send(view.pid, {make_ref(), {:error, :cli_failed}})
    assert has_element?(view, "#improve-error-banner", "Improvement failed")
  end

  test "auto-selects active project when no query param provided, and handles patch without project", %{
    admin_conn: conn,
    admin_user: _admin_user
  } do
    project = create_test_project(%{active: true})

    assert {:ok, view, _html} = live(conn, ~p"/settings/roles")
    assert has_element?(view, "#project-selector option[selected]", project.name)

    # Patch without project param when current_project_id is already set
    assert {:ok, view2, _html} = live(conn, ~p"/settings/roles")
    assert render(view2) =~ project.name
  end

  test "select_project event updates selected project", %{
    admin_conn: conn,
    admin_user: _admin_user
  } do
    project1 = create_test_project(%{name: "Project One"})
    project2 = create_test_project(%{name: "Project Two"})

    assert {:ok, view, _html} = live(conn, ~p"/settings/roles?project=#{project1.id}")
    assert has_element?(view, "#project-selector option[selected]", "Project One")

    view
    |> form("#project-selector-form", %{"project_id" => project2.id})
    |> render_change()

    assert_patched(view, ~p"/settings/roles?project=#{project2.id}")
  end

  test "renders available models dropdown and validates custom model and name in create modal", %{
    admin_conn: conn,
    admin_user: _admin_user
  } do
    project = create_test_project()

    assert {:ok, view, _html} = live(conn, ~p"/settings/roles?project=#{project.id}")

    # Open create modal without stage
    view |> element("#add-custom-role-button") |> render_click()
    assert has_element?(view, "#role-editor-modal")

    # Options from available_models are rendered
    assert has_element?(view, "#role-model-select option[value='claude-sonnet-5']")

    # Select custom model option
    view
    |> form("#role-form", %{
      "role" => %{
        "model_choice" => "__custom__"
      }
    })
    |> render_change()

    assert has_element?(view, "#custom-model-input-container")

    # Submit invalid form with empty name and custom model choice with empty custom_model
    view
    |> form("#role-form", %{
      "role" => %{
        "name" => "",
        "description" => "A description",
        "stage" => "",
        "cli_backend" => "claude",
        "model_choice" => "__custom__",
        "custom_model" => "",
        "reasoning_effort" => "high",
        "system_prompt" => "Prompt",
        "max_concurrent" => "invalid"
      }
    })
    |> render_submit()

    assert has_element?(view, "#role-name-error", "can't be blank")
    assert has_element?(view, "#role-model-error", "can't be blank")

    # Validate with model_choice: nil
    render_hook(view, "validate_role", %{
      "role" => %{
        "cli_backend" => "claude",
        "model_choice" => nil,
        "custom_model" => ""
      }
    })

    # Test fetch_models_for_backend error branch
    stub(Rail.Backends, :fetch_available_models, fn _scope, _backend, _opts -> {:error, :failed} end)
    render_hook(view, "change_backend", %{"role" => %{"cli_backend" => "agy"}})
  end

  test "handles stage_default_name and max_concurrent variations in create modal", %{
    admin_conn: conn,
    admin_user: _admin_user
  } do
    project = create_test_project()

    assert {:ok, view, _html} = live(conn, ~p"/settings/roles?project=#{project.id}")

    # Open with atom/string stage that exists in default role names
    render_hook(view, "open_create_modal", %{"stage" => "engineer"})
    assert has_element?(view, "#role-editor-modal")
    assert has_element?(view, "input[name='role[name]'][value='Engineer']")

    # Open with unknown stage string
    render_hook(view, "open_create_modal", %{"stage" => "unknown_custom_stage_test"})
    assert has_element?(view, "input[name='role[name]'][value='Unknown_custom_stage_test']")

    # Submit with integer max_concurrent
    view
    |> form("#role-form", %{
      "role" => %{
        "name" => "Valid Name",
        "description" => "Desc",
        "stage" => "",
        "cli_backend" => "claude",
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

    view
    |> form("#role-form", %{
      "role" => %{
        "name" => "Another Valid Name",
        "description" => "Desc",
        "stage" => "",
        "cli_backend" => "claude",
        "model_choice" => "claude-sonnet-5",
        "reasoning_effort" => "high",
        "system_prompt" => "Prompt",
        "max_concurrent" => nil
      }
    })
    |> render_submit()

    refute has_element?(view, "#role-editor-modal")
  end

  test "handles open_delete_modal with non-existent role and delete_role when modal_role is nil", %{
    admin_conn: conn,
    admin_user: _admin_user
  } do
    project = create_test_project()

    assert {:ok, view, _html} = live(conn, ~p"/settings/roles?project=#{project.id}")

    render_hook(view, "open_delete_modal", %{"role_id" => "non_existent"})
    refute has_element?(view, "#delete-role-modal")

    render_hook(view, "delete_role", %{})
    refute has_element?(view, "#delete-role-modal")
  end

  test "handles export, import, and copy modal edge cases", %{
    admin_conn: conn,
    admin_user: _admin_user
  } do
    project = create_test_project()
    other_project = create_test_project()

    assert {:ok, view, _html} = live(conn, ~p"/settings/roles?project=#{project.id}")

    # Select project event via form change
    view
    |> form("#project-selector-form")
    |> render_change(%{"project_id" => other_project.id})

    assert_patched(view, ~p"/settings/roles?project=#{other_project.id}")

    # Validate import event
    view |> element("#import-roles-button") |> render_click()
    assert has_element?(view, "#import-roles-modal")
    render_change(element(view, "#import-roles-form"), %{"import_json" => "[]"})

    # Close import modal
    view |> element("#cancel-import-button") |> render_click()
    refute has_element?(view, "#import-roles-modal")

    # Validate copy event
    view |> element("#copy-roles-button") |> render_click()
    assert has_element?(view, "#copy-roles-modal")
    render_change(element(view, "#copy-roles-form"), %{"source_project_id" => project.id})

    # Trigger copy_roles error branch
    stub(Roles, :copy_roles, fn _scope, _target, _source, _opts -> {:error, :failed} end)
    render_hook(view, "copy_roles", %{"source_project_id" => project.id})

    # Trigger export_roles error branch
    stub(Roles, :export_roles, fn _scope, _project_id -> {:error, :failed} end)
    render_hook(view, "open_export_modal", %{})
    refute has_element?(view, "#export-roles-modal")
  end

  test "improve role displays error banner when improve_role fails", %{
    admin_conn: conn,
    admin_user: admin_user
  } do
    stub(Roles, :improve_role, fn _scope, _role, _model -> {:error, :stubbed_failure} end)

    project = create_test_project()
    scope = Rail.Scope.for_user(admin_user)

    assert {:ok, %Role{id: role_id}} =
             Roles.create_role(scope, project.id, %{
               name: "Unlisted Model Role",
               stage: :qa,
               cli_backend: :claude,
               model: "unlisted-custom-model-id",
               system_prompt: "QA instructions"
             })

    role_run = create_test_role_run(role_id: role_id, status: :finished, completed_at: nil, output: "Output")

    assert {:ok, view, _html} = live(conn, ~p"/settings/roles?project=#{project.id}")

    # Open improve modal (tests selected_model fallback to List.first(models).id and format_run_time(nil))
    view |> element("#improve-role-button-#{role_id}") |> render_click()
    assert has_element?(view, "#improve-role-modal")
    assert has_element?(view, "#evidence-run-#{role_run.task_id}", "recently")

    # Start improvement and verify failure handling
    view |> element("#start-improvement-button") |> render_click()
    assert has_element?(view, "#improve-error-banner", "Improvement failed: :stubbed_failure")
  end

  test "improve role handles cancellation and closing modal while running", %{
    admin_conn: conn,
    admin_user: admin_user
  } do
    stub(Roles, :improve_role, fn _scope, _role, _model ->
      Process.sleep(2_000)

      {:ok,
       %RoleInstructionProposal{
         role_id: "test",
         model_id: "claude-sonnet-5",
         current: "c",
         proposed: "p",
         rationale: "r",
         diff: "d",
         sources: []
       }}
    end)

    project = create_test_project()
    scope = Rail.Scope.for_user(admin_user)

    assert {:ok, %Role{id: role_id}} =
             Roles.create_role(scope, project.id, %{
               name: "Slow Running Role",
               stage: :qa,
               cli_backend: :claude,
               model: "claude-sonnet-5",
               system_prompt: "QA instructions"
             })

    create_test_role_run(role_id: role_id, status: :finished, output: "Output")

    assert {:ok, view, _html} = live(conn, ~p"/settings/roles?project=#{project.id}")

    # Start improvement and cancel while running
    view |> element("#improve-role-button-#{role_id}") |> render_click()
    view |> element("#start-improvement-button") |> render_click()
    assert has_element?(view, "#improve-step-running")
    view |> element("#running-cancel-button") |> render_click()
    refute has_element?(view, "#improve-role-modal")

    # Start improvement again and close modal via close_modal while running
    view |> element("#improve-role-button-#{role_id}") |> render_click()
    view |> element("#start-improvement-button") |> render_click()
    assert has_element?(view, "#improve-step-running")
    render_hook(view, "close_modal", %{})
    refute has_element?(view, "#improve-role-modal")
  end

  test "improve role handles missing role and invalid proposal on approval", %{
    admin_conn: conn,
    admin_user: admin_user
  } do
    project = create_test_project()
    scope = Rail.Scope.for_user(admin_user)

    assert {:ok, %Role{id: role_id} = role} =
             Roles.create_role(scope, project.id, %{
               name: "To Be Deleted Role",
               stage: :qa,
               cli_backend: :claude,
               model: "claude-sonnet-5",
               system_prompt: "QA instructions"
             })

    create_test_role_run(role_id: role_id, status: :finished, output: "Output")

    assert {:ok, view, _html} = live(conn, ~p"/settings/roles?project=#{project.id}")

    view |> element("#improve-role-button-#{role_id}") |> render_click()

    # Delete role from database
    Roles.delete_role(scope, role)

    # Transition to proposal step
    proposal = %RoleInstructionProposal{
      role_id: role_id,
      model_id: "claude-sonnet-5",
      current: "QA instructions",
      proposed: "New instructions",
      rationale: "Rationale",
      diff: "diff",
      sources: []
    }

    send(view.pid, {make_ref(), {:ok, proposal}})
    send(view.pid, {:DOWN, make_ref(), :process, self(), :normal})

    # Verifies role-missing-warning is displayed and button is disabled
    assert has_element?(view, "#role-missing-warning", "was removed on disk")
    assert has_element?(view, "#approve-proposal-button[disabled]")

    # Attempt to approve proposal when role no longer exists
    render_hook(view, "approve_proposal", %{})
    assert has_element?(view, "#improve-error-banner", "Role no longer exists.")

    # Recreate role to test approval with invalid proposal (empty proposed string)
    assert {:ok, %Role{id: new_role_id}} =
             Roles.create_role(scope, project.id, %{
               name: "Another Role",
               stage: :rebase,
               cli_backend: :claude,
               model: "claude-sonnet-5",
               system_prompt: "Rebase instructions"
             })

    create_test_role_run(role_id: new_role_id, status: :finished, output: "Output")
    assert {:ok, view2, _html} = live(conn, ~p"/settings/roles?project=#{project.id}")

    view2 |> element("#improve-role-button-#{new_role_id}") |> render_click()

    invalid_proposal = %RoleInstructionProposal{
      role_id: new_role_id,
      model_id: "claude-sonnet-5",
      current: "Rebase instructions",
      proposed: "",
      rationale: "Empty proposed",
      diff: "diff",
      sources: []
    }

    send(view2.pid, {make_ref(), {:ok, invalid_proposal}})
    view2 |> element("#approve-proposal-button") |> render_click()
    assert has_element?(view2, "#improve-error-banner", "Failed to apply improved instructions.")
  end
end
