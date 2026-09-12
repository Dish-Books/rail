defmodule Rail.Pipeline.Actions.ListTasksTest do
  use Rail.DataCase, async: true

  import Ecto.Query

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    scope = system_scope()

    {:ok, workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "List Tasks Workspace",
        external_id: "lin_ws_list_tasks",
        token: "lin_api_token_list_tasks",
        webhook_secret: "whsec_list_tasks"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "List Tasks Project 7101",
        github_repo: "org/list-tasks-7101",
        github_installation_id: 7101,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_list_tasks_7101",
        linear_team_key: "P7101",
        default_branch: "main",
        clone_path: "/tmp/repos/list-tasks-7101",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_list_tasks_1",
      "identifier" => "LTS-1",
      "title" => "List Tasks Issue"
    })

    {:ok, issue} = Issues.capture_issue(scope, project, "List Tasks Issue")

    {:ok, task} = Pipeline.create_task(issue, :product)

    %{project: project, issue: issue, task: task}
  end

  test "filters tasks by stage and stage_state", %{project: project, task: task} do
    {:ok, %Task{id: prod_id}} =
      Pipeline.update_task(task, %{
        stage: :product,
        stage_state: :queued
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_list_tasks_7103",
      "identifier" => "TSK-7103",
      "title" => "Task 7103"
    })

    {:ok, issue_7103} = Issues.capture_issue(system_scope(), project, "Task 7103")

    {:ok, %Task{id: eng_q_id}} = Pipeline.create_task(issue_7103, :product)

    {:ok, %Task{id: eng_q_id}} =
      Pipeline.update_task(Repo.get!(Task, eng_q_id), %{
        stage: :engineer,
        stage_state: :queued
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_list_tasks_7104",
      "identifier" => "TSK-7104",
      "title" => "Task 7104"
    })

    {:ok, issue_7104} = Issues.capture_issue(system_scope(), project, "Task 7104")

    {:ok, t_eng_running} = Pipeline.create_task(issue_7104, :product)

    {:ok, _t_eng_running} =
      Pipeline.update_task(t_eng_running, %{
        stage: :engineer,
        stage_state: :running
      })

    scope = Scope.for_system()

    # Filter by stage
    assert [%Task{id: ^prod_id}] = Pipeline.list_tasks(project.id, stage: :product)

    # Filter by stage and stage_state
    assert [%Task{id: ^eng_q_id}] =
             Pipeline.list_tasks(project.id, stage: :engineer, stage_state: :queued)
  end

  test "supports custom order_by", %{project: project, task: task} do
    Repo.update_all(from(i in Issue, where: i.id == ^Repo.get!(Task, task.id).issue_id), set: [title: "Alpha"])

    {:ok, %Task{id: id1}} =
      Pipeline.update_task(task, %{})

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_list_tasks_7105",
      "identifier" => "TSK-7105",
      "title" => "Beta"
    })

    {:ok, issue_7105} = Issues.capture_issue(system_scope(), project, "Beta")

    {:ok, %Task{id: id2}} = Pipeline.create_task(issue_7105, :product)

    scope = Scope.for_system()

    assert [%Task{id: ^id2}, %Task{id: ^id1}] =
             Pipeline.list_tasks(project.id, order_by: [desc: :inserted_at])
  end

  test "lists tasks across all projects when project_id is nil", %{task: task} do
    {:ok, _p1} =
      Projects.create_project(system_scope(), %{
        name: "List Tasks Project 7107",
        github_repo: "org/list-tasks-7107",
        github_installation_id: 7107,
        linear_team_id: "team_list_tasks_7107",
        linear_team_key: "P7107",
        default_branch: "main",
        clone_path: "/tmp/repos/list-tasks-7107",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    {:ok, p2} =
      Projects.create_project(system_scope(), %{
        name: "List Tasks Project 7108",
        github_repo: "org/list-tasks-7108",
        github_installation_id: 7108,
        linear_team_id: "team_list_tasks_7108",
        linear_team_key: "P7108",
        default_branch: "main",
        clone_path: "/tmp/repos/list-tasks-7108",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    Repo.update_all(from(i in Issue, where: i.id == ^Repo.get!(Task, task.id).issue_id), set: [title: "P1 Task"])

    {:ok, %Task{id: id1}} =
      Pipeline.update_task(task, %{})

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_list_tasks_7106",
      "identifier" => "TSK-7106",
      "title" => "P2 Task"
    })

    {:ok, issue_7106} = Issues.capture_issue(system_scope(), p2, "P2 Task")

    {:ok, %Task{id: id2}} = Pipeline.create_task(issue_7106, :product)

    system_scope = Scope.for_system()
    user_scope = Scope.for_user(%{admin: false})

    all_tasks_system = Pipeline.list_tasks(nil)
    all_ids_system = Enum.map(all_tasks_system, & &1.id)
    assert id1 in all_ids_system
    assert id2 in all_ids_system

    all_tasks_user = Pipeline.list_tasks(nil)
    all_ids_user = Enum.map(all_tasks_user, & &1.id)
    assert id1 in all_ids_user
    assert id2 in all_ids_user
  end

  test "supports preload option", %{project: %Project{id: expected_project_id}, task: task} do
    Repo.update_all(from(i in Issue, where: i.id == ^Repo.get!(Task, task.id).issue_id), set: [title: "Preload Task"])

    {:ok, %Task{id: id1}} =
      Pipeline.update_task(task, %{})

    scope = Scope.for_system()

    assert [%Task{id: ^id1, project: %Project{id: ^expected_project_id}}] =
             Pipeline.list_tasks(expected_project_id, preload: [:project])
  end
end
