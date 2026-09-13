defmodule Rail.Pipeline.Actions.MarkPrReadyTest do
  use Rail.DataCase, async: true

  import RailTest.Mocks.GitHub

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Roles
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    {:ok, backend} =
      Rail.Backends.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true"})

    scope = system_scope()

    {:ok, workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Mark PR Ready Workspace",
        external_id: "lin_ws_mark_pr_ready",
        token: "lin_api_token_mark_pr_ready",
        webhook_secret: "whsec_mark_pr_ready"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Mark PR Ready Project 8901",
        github_repo: "org/mark-pr-ready-8901",
        github_installation_id: 8901,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_mark_pr_ready_8901",
        linear_team_key: "P8901",
        default_branch: "main",
        clone_path: "/tmp/repos/mark-pr-ready-8901",
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
            backend_id: backend.id,
            stage: stage,
            name: "#{stage} role",
            model: "claude-3-7-sonnet",
            system_prompt: "You are the #{stage} agent."
          })

        {stage, role}
      end)

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_mark_pr_ready_1",
      "identifier" => "MPR-1",
      "title" => "Mark PR Ready Issue"
    })

    {:ok, issue} = Issues.create_issue(project, %{description: "Mark PR Ready Issue"})

    {:ok, task} = Pipeline.create_task(issue, :product)

    %{project: project, issue: issue, task: task, roles: roles}
  end

  test "returns :no_pr and records error when task has no pr_number", %{project: _project, task: _task} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Mark PR Ready Project 8902",
        github_repo: "org/mark-pr-ready-8902",
        github_installation_id: 8902,
        linear_team_id: "team_mark_pr_ready_8902",
        linear_team_key: "P8902",
        default_branch: "main",
        clone_path: "/tmp/repos/mark-pr-ready-8902",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_mark_pr_ready_8903",
      "identifier" => "TSK-8903",
      "title" => "Task 8903"
    })

    {:ok, issue_8903} = Issues.create_issue(project, %{description: "Task 8903"})

    {:ok, %Task{id: _task_id} = task} = Pipeline.create_task(issue_8903, :product)

    {:ok, %Task{} = task} =
      Pipeline.update_task(task, %{
        stage: :ready_to_merge,
        pr_number: nil,
        pr_is_draft: true
      })

    assert {:error, :no_pr} = Pipeline.mark_pr_ready(task)
  end

  test "promotes draft PR, clears error, and triggers mergeability refresh", %{project: _project, task: _task} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Mark PR Ready Project 8904",
        github_repo: "testorg/markready",
        github_installation_id: 8904,
        linear_team_id: "team_mark_pr_ready_8904",
        linear_team_key: "P8904",
        default_branch: "main",
        clone_path: "/tmp/repos/mark-pr-ready-8904",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_mark_pr_ready_8906",
      "identifier" => "TSK-8906",
      "title" => "Task 8906"
    })

    {:ok, issue_8906} = Issues.create_issue(project, %{description: "Task 8906"})

    {:ok, %Task{id: _task_id} = task} = Pipeline.create_task(issue_8906, :product)

    {:ok, %Task{} = task} =
      Pipeline.update_task(task, %{
        stage: :ready_to_merge,
        pr_number: 123,
        pr_is_draft: true,
        mergeability: :unknown
      })

    mock_installation_token_success(installation_id: 8904)
    mock_mark_pull_request_ready_success("testorg/markready", 123, user_token: "mock_installation_token")
    mock_installation_token_success(installation_id: 8904)
    mock_pull_request_state_success("testorg/markready", 123, mergeable: true, draft: false)

    assert {:ok, %Task{pr_is_draft: false, mergeability: :mergeable}} =
             Pipeline.mark_pr_ready(task)
  end

  test "records error and leaves draft status true when GitHub mark ready fails", %{project: _project, task: _task} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Mark PR Ready Project 8907",
        github_repo: "testorg/markready",
        github_installation_id: 8907,
        linear_team_id: "team_mark_pr_ready_8907",
        linear_team_key: "P8907",
        default_branch: "main",
        clone_path: "/tmp/repos/mark-pr-ready-8907",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_mark_pr_ready_8908",
      "identifier" => "TSK-8908",
      "title" => "Task 8908"
    })

    {:ok, issue_8908} = Issues.create_issue(project, %{description: "Task 8908"})

    {:ok, %Task{id: _task_id} = task} = Pipeline.create_task(issue_8908, :product)

    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(task, %{
        stage: :ready_to_merge,
        pr_number: 124,
        pr_is_draft: true
      })

    mock_mark_pull_request_ready_mutation_http_error("testorg/markready", 124, 422, "Draft cannot be converted")

    assert {:error, {:github_api_error, 422, %{"message" => "Draft cannot be converted"}}} =
             Pipeline.mark_pr_ready(task, token: "tok_test")

    reloaded = Repo.get!(Task, task_id)
    assert reloaded.pr_is_draft == true
  end

  test "records error when GitHub returns binary error message", %{project: _project, task: _task} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Mark PR Ready Project 8909",
        github_repo: "testorg/markready",
        github_installation_id: 8909,
        linear_team_id: "team_mark_pr_ready_8909",
        linear_team_key: "P8909",
        default_branch: "main",
        clone_path: "/tmp/repos/mark-pr-ready-8909",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_mark_pr_ready_8910",
      "identifier" => "TSK-8910",
      "title" => "Task 8910"
    })

    {:ok, issue_8910} = Issues.create_issue(project, %{description: "Task 8910"})

    {:ok, task} = Pipeline.create_task(issue_8910, :product)

    {:ok, task} =
      Pipeline.update_task(task, %{
        stage: :ready_to_merge,
        pr_number: 126,
        pr_is_draft: true
      })

    mock_mark_pull_request_ready_query_not_found("testorg/markready", 126)

    assert {:error, {:github_api_error, 404, "Repository not found"}} =
             Pipeline.mark_pr_ready(task, token: "tok_test")
  end

  test "records error when GitHub returns graphql error", %{project: _project, task: _task} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Mark PR Ready Project 8911",
        github_repo: "testorg/markready",
        github_installation_id: 8911,
        linear_team_id: "team_mark_pr_ready_8911",
        linear_team_key: "P8911",
        default_branch: "main",
        clone_path: "/tmp/repos/mark-pr-ready-8911",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_mark_pr_ready_8912",
      "identifier" => "TSK-8912",
      "title" => "Task 8912"
    })

    {:ok, issue_8912} = Issues.create_issue(project, %{description: "Task 8912"})

    {:ok, task} = Pipeline.create_task(issue_8912, :product)

    {:ok, task} =
      Pipeline.update_task(task, %{
        stage: :ready_to_merge,
        pr_number: 127,
        pr_is_draft: true
      })

    mock_mark_pull_request_ready_graphql_error("Some GraphQL failure")

    assert {:error, {:github_graphql_error, _errors}} =
             Pipeline.mark_pr_ready(task, token: "tok_test")
  end

  test "returns error when project is not found", %{project: _project, task: _task} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Mark PR Ready Project 8913",
        github_repo: "org/mark-pr-ready-8913",
        github_installation_id: 8913,
        linear_team_id: "team_mark_pr_ready_8913",
        linear_team_key: "P8913",
        default_branch: "main",
        clone_path: "/tmp/repos/mark-pr-ready-8913",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_mark_pr_ready_8914",
      "identifier" => "TSK-8914",
      "title" => "Task 8914"
    })

    {:ok, issue_8914} = Issues.create_issue(project, %{description: "Task 8914"})

    {:ok, task} = Pipeline.create_task(issue_8914, :product)

    {:ok, task} =
      Pipeline.update_task(task, %{
        pr_number: 125
      })

    Repo.delete!(project)

    assert {:error, :project_not_found} = Pipeline.mark_pr_ready(task)
  end
end
