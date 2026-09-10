defmodule Rail.Pipeline.Actions.BringLocalTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Projects.Schemas.LinearWorkspace
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Scope
  alias Rail.Users
  alias Rail.Users.Schemas.User
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    scope = system_scope()

    {:ok, workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Bring Local Workspace",
        external_id: "lin_ws_bring_local",
        token: "lin_api_token_bring_local",
        webhook_secret: "whsec_bring_local"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Bring Local Project 9601",
        github_repo: "org/bring-local-9601",
        github_installation_id: 9601,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_bring_local_9601",
        linear_team_key: "P9601",
        clone_path: "/tmp/repos/bring-local-9601",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    roles =
      Map.new([:product, :design, :architect, :engineer, :review, :qa, :qa_lead, :demo], fn stage ->
        {:ok, role} =
          Roles.create_role(scope, project, %{
            stage: stage,
            name: "#{stage} role",
            model: "claude-3-7-sonnet",
            system_prompt: "You are the #{stage} agent."
          })

        {stage, role}
      end)

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_bring_local_1",
      "identifier" => "BRL-1",
      "title" => "Bring Local Issue"
    })

    {:ok, issue} = Issues.capture_issue(scope, project, "Bring Local Issue")

    LinearMock.mock_update_issue_success(%{"id" => "lin_bring_local_1"})

    {:ok, task} = Pipeline.bring_local(scope, issue)

    %{project: project, issue: issue, task: task, roles: roles}
  end

  test "returns not_authorized error for nil or unauthenticated scope", %{issue: issue} do
    issue = %Issue{id: "iss_123"}
    assert {:error, :not_authorized} = Pipeline.bring_local(nil, issue)
    assert {:error, :not_authorized} = Pipeline.bring_local(%Scope{user: nil, system: false}, issue)
  end

  test "returns existing task if already brought local (idempotency)", %{project: project, issue: issue, task: task} do
    LinearMock.mock_create_issue_success(%{
      "id" => "lin_bring_local_9602",
      "identifier" => "ISS-9602",
      "title" => "Bring Local Issue 9602"
    })

    {:ok, issue} = Issues.capture_issue(system_scope(), project, "Bring Local Issue 9602")

    {:ok, %Task{id: existing_id}} =
      Pipeline.update_task(system_scope(), task.id, %{
        issue_id: issue.id
      })

    scope = Scope.for_system()

    assert {:ok, %Task{id: ^existing_id}} = Pipeline.bring_local(scope, issue)
  end

  test "brings issue local, updates Linear state, creates task, and broadcasts event", %{project: project, issue: issue} do
    {:ok, %LinearWorkspace{id: ws_id}} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Bring Local Workspace 9603",
        external_id: "lin_ws_bring_local_9603",
        token: "lin_api_token_bring_local_9603",
        webhook_secret: "whsec_bring_local_9603"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Bring Local Project 9604",
        github_repo: "org/bring-local-9604",
        github_installation_id: 9604,
        linear_team_id: "team_bring_1",
        linear_team_key: "P9604",
        clone_path: "/tmp/repos/bring-local-9604",
        linear_state_ids: %{"in_progress" => "st_in_prog_1"},
        linear_workspace_id: ws_id
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_bring_1",
      "identifier" => "ENG-5001",
      "title" => "Implement Core Pipeline"
    })

    {:ok, %Issue{id: issue_id} = issue} = Issues.capture_issue(system_scope(), project, "Implement Core Pipeline")

    LinearMock.mock_update_issue_success(%{"id" => "lin_bring_1"})

    {:ok, %Issue{id: issue_id} = issue} =
      Issues.update_issue(system_scope(), %Issue{id: issue_id} = issue, %{
        description: "Full bring_local integration",
        branch_name: "eng-5001-pipeline",
        state: :triage
      })

    {:ok, %User{id: user_id} = user} =
      Users.register_oauth_user(%{
        github_id: "gh_bring_local_9606",
        login: "bring_local_user_9606",
        email: "bring_local_user_9606@example.com",
        github_token: "gho_token_9606"
      })

    scope = Scope.for_user(user)

    LinearMock.mock_update_issue_success(%{
      "id" => "lin_bring_1",
      "identifier" => "ENG-5001",
      "title" => issue.title,
      "description" => issue.description,
      "state" => %{"id" => "st_in_prog_1", "name" => "In Progress", "type" => "started"},
      "branchName" => "eng-5001-pipeline",
      "url" => issue.url,
      "createdAt" => "2026-09-01T10:00:00.000Z",
      "updatedAt" => "2026-09-04T10:00:00.000Z"
    })

    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")

    assert {:ok,
            %Task{
              id: task_id,
              issue_id: ^issue_id,
              owner_user_id: ^user_id,
              title: "Implement Core Pipeline",
              description: "Full bring_local integration",
              stage: :product,
              stage_state: :queued,
              worktree_name: "eng-5001-pipeline"
            }} = Pipeline.bring_local(scope, issue, user)

    # Verify PubSub broadcast
    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :brought_local}}
  end

  test "derives worktree name from identifier when branch_name is nil", %{project: project, issue: issue} do
    {:ok, %LinearWorkspace{id: ws_id}} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Bring Local Workspace 9607",
        external_id: "lin_ws_bring_local_9607",
        token: "lin_api_token_bring_local_9607",
        webhook_secret: "whsec_bring_local_9607"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Bring Local Project 9608",
        github_repo: "org/bring-local-9608",
        github_installation_id: 9608,
        linear_team_id: "team_bring_2",
        linear_team_key: "P9608",
        clone_path: "/tmp/repos/bring-local-9608",
        linear_state_ids: %{"in_progress" => "st_in_prog_2"},
        linear_workspace_id: ws_id
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_bring_2",
      "identifier" => "PROJ/FEAT #42",
      "title" => "Special Identifier"
    })

    {:ok, issue} = Issues.capture_issue(system_scope(), project, "Special Identifier")

    LinearMock.mock_update_issue_success(%{"id" => "lin_bring_2"})

    {:ok, issue} =
      Issues.update_issue(system_scope(), issue, %{
        branch_name: nil,
        state: :backlog
      })

    scope = Scope.for_system()

    LinearMock.mock_update_issue_success(%{
      "id" => "lin_bring_2",
      "identifier" => "PROJ/FEAT #42",
      "title" => issue.title,
      "description" => issue.description,
      "state" => %{"id" => "st_in_prog_2", "name" => "In Progress", "type" => "started"},
      "branchName" => nil,
      "url" => issue.url,
      "createdAt" => "2026-09-01T10:00:00.000Z",
      "updatedAt" => "2026-09-04T10:00:00.000Z"
    })

    assert {:ok, %Task{worktree_name: "proj-feat--42"}} = Pipeline.bring_local(scope, issue)
  end

  test "returns error when Linear move_state fails", %{project: project, issue: issue} do
    {:ok, %LinearWorkspace{id: ws_id}} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Bring Local Workspace 9610",
        external_id: "lin_ws_bring_local_9610",
        token: "lin_api_token_bring_local_9610",
        webhook_secret: "whsec_bring_local_9610"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Bring Local Project 9611",
        github_repo: "org/bring-local-9611",
        github_installation_id: 9611,
        linear_team_id: "team_bring_err",
        linear_team_key: "P9611",
        clone_path: "/tmp/repos/bring-local-9611",
        linear_state_ids: %{"in_progress" => "st_in_prog_err"},
        linear_workspace_id: ws_id
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_bring_err",
      "identifier" => "ENG-ERR",
      "title" => "Bring Local Issue 9612"
    })

    {:ok, issue} = Issues.capture_issue(system_scope(), project, "Bring Local Issue 9612")

    LinearMock.mock_mutation_failure("issueUpdate")
    scope = Scope.for_system()

    assert {:error, {:linear_mutation_failed, "issueUpdate"}} = Pipeline.bring_local(scope, issue)
    refute Repo.exists?(from t in Task, where: t.issue_id == ^issue.id)
  end

  test "returns existing task when already brought local", %{project: project, issue: issue, task: task} do
    LinearMock.mock_create_issue_success(%{
      "id" => "lin_bring_local_9613",
      "identifier" => "ENG-EXIST",
      "title" => "Bring Local Issue 9613"
    })

    {:ok, %Issue{id: issue_id} = issue} = Issues.capture_issue(system_scope(), project, "Bring Local Issue 9613")

    {:ok, %Task{id: existing_id}} =
      Pipeline.update_task(system_scope(), task.id, %{
        issue_id: issue_id
      })

    scope = Scope.for_system()

    assert {:ok, %Task{id: ^existing_id}} = Pipeline.bring_local(scope, issue)
  end

  test "resolves owner_user_id from scope when owner_user argument is omitted", %{project: project, issue: issue} do
    {:ok, %LinearWorkspace{id: ws_id}} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Bring Local Workspace 9614",
        external_id: "lin_ws_bring_local_9614",
        token: "lin_api_token_bring_local_9614",
        webhook_secret: "whsec_bring_local_9614"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Bring Local Project 9615",
        github_repo: "org/bring-local-9615",
        github_installation_id: 9615,
        linear_team_id: "team_bring_scope_user",
        linear_team_key: "P9615",
        clone_path: "/tmp/repos/bring-local-9615",
        linear_state_ids: %{"in_progress" => "st_in_prog_scope"},
        linear_workspace_id: ws_id
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_bring_scope",
      "identifier" => "ENG-SCOPE",
      "title" => "Bring Local Issue 9616"
    })

    {:ok, issue} = Issues.capture_issue(system_scope(), project, "Bring Local Issue 9616")

    LinearMock.mock_update_issue_success(%{"id" => "lin_bring_scope"})

    {:ok, issue} =
      Issues.update_issue(system_scope(), issue, %{
        state: :triage
      })

    {:ok, %User{id: user_id} = user} =
      Users.register_oauth_user(%{
        github_id: "gh_bring_local_9617",
        login: "bring_local_user_9617",
        email: "bring_local_user_9617@example.com",
        github_token: "gho_token_9617"
      })

    scope = Scope.for_user(user)

    LinearMock.mock_update_issue_success(%{
      "id" => "lin_bring_scope",
      "identifier" => "ENG-SCOPE",
      "title" => issue.title,
      "description" => issue.description,
      "state" => %{"id" => "st_in_prog_scope", "name" => "In Progress", "type" => "started"},
      "branchName" => nil,
      "url" => issue.url,
      "createdAt" => "2026-09-01T10:00:00.000Z",
      "updatedAt" => "2026-09-04T10:00:00.000Z"
    })

    assert {:ok, %Task{owner_user_id: ^user_id}} = Pipeline.bring_local(scope, issue)
  end

  test "returns not_authorized when scope is unauthorized", %{project: project, issue: issue} do
    LinearMock.mock_create_issue_success(%{
      "id" => "lin_bring_local_9618",
      "identifier" => "ENG-UNAUTH",
      "title" => "Bring Local Issue 9618"
    })

    {:ok, issue} = Issues.capture_issue(system_scope(), project, "Bring Local Issue 9618")

    assert {:error, :not_authorized} = Pipeline.bring_local(nil, issue)
    assert {:error, :not_authorized} = Pipeline.bring_local(%Scope{user: nil, system: false}, issue)
  end
end
