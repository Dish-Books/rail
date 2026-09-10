defmodule Rail.Pipeline.Actions.ListTasksTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Projects.Schemas.Project
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

    LinearMock.mock_update_issue_success(%{"id" => "lin_list_tasks_1"})

    {:ok, task} = Pipeline.create_task(issue)

    %{project: project, issue: issue, task: task}
  end

  test "lists tasks for project under system and user scope", %{project: project, task: task} do
    {:ok, %Task{id: id1}} =
      Pipeline.update_task(system_scope(), task.id, %{
        title: "T1"
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_list_tasks_7102",
      "identifier" => "TSK-7102",
      "title" => "T2"
    })

    {:ok, issue_7102} = Issues.capture_issue(system_scope(), project, "T2")

    LinearMock.mock_update_issue_success(%{"id" => "lin_task_list_tasks_7102"})

    {:ok, %Task{id: id2}} = Pipeline.create_task(issue_7102)

    system_scope = Scope.for_system()
    user_scope = Scope.for_user(%{admin: false})

    assert [%Task{id: ^id1}, %Task{id: ^id2}] = Pipeline.list_tasks(system_scope, project.id)
    assert [%Task{id: ^id1}, %Task{id: ^id2}] = Pipeline.list_tasks(user_scope, project.id)
  end

  test "returns empty list for unauthorized scope", %{project: project, task: task} do
    _t1 = task

    assert [] = Pipeline.list_tasks(nil, project.id)
    assert [] = Pipeline.list_tasks(%Scope{user: nil, system: false}, project.id)
  end

  test "filters tasks by stage and stage_state", %{project: project, task: task} do
    {:ok, %Task{id: prod_id}} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :product,
        stage_state: :queued
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_list_tasks_7103",
      "identifier" => "TSK-7103",
      "title" => "Task 7103"
    })

    {:ok, issue_7103} = Issues.capture_issue(system_scope(), project, "Task 7103")

    LinearMock.mock_update_issue_success(%{"id" => "lin_task_list_tasks_7103"})

    {:ok, %Task{id: eng_q_id}} = Pipeline.create_task(issue_7103)

    {:ok, %Task{id: eng_q_id}} =
      Pipeline.update_task(system_scope(), %Task{id: eng_q_id}.id, %{
        stage: :engineer,
        stage_state: :queued
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_list_tasks_7104",
      "identifier" => "TSK-7104",
      "title" => "Task 7104"
    })

    {:ok, issue_7104} = Issues.capture_issue(system_scope(), project, "Task 7104")

    LinearMock.mock_update_issue_success(%{"id" => "lin_task_list_tasks_7104"})

    {:ok, _t_eng_running} = Pipeline.create_task(issue_7104)

    {:ok, _t_eng_running} =
      Pipeline.update_task(system_scope(), _t_eng_running.id, %{
        stage: :engineer,
        stage_state: :running
      })

    scope = Scope.for_system()

    # Filter by stage
    assert [%Task{id: ^prod_id}] = Pipeline.list_tasks(scope, project.id, stage: :product)

    # Filter by stage and stage_state
    assert [%Task{id: ^eng_q_id}] =
             Pipeline.list_tasks(scope, project.id, stage: :engineer, stage_state: :queued)
  end

  test "supports custom order_by", %{project: project, task: task} do
    {:ok, %Task{id: id1}} =
      Pipeline.update_task(system_scope(), task.id, %{
        title: "Alpha"
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_list_tasks_7105",
      "identifier" => "TSK-7105",
      "title" => "Beta"
    })

    {:ok, issue_7105} = Issues.capture_issue(system_scope(), project, "Beta")

    LinearMock.mock_update_issue_success(%{"id" => "lin_task_list_tasks_7105"})

    {:ok, %Task{id: id2}} = Pipeline.create_task(issue_7105)

    scope = Scope.for_system()

    assert [%Task{id: ^id2}, %Task{id: ^id1}] =
             Pipeline.list_tasks(scope, project.id, order_by: [desc: :inserted_at])
  end

  test "lists tasks across all projects when project_id is nil", %{task: task} do
    {:ok, _p1} =
      Projects.create_project(system_scope(), %{
        name: "List Tasks Project 7107",
        github_repo: "org/list-tasks-7107",
        github_installation_id: 7107,
        linear_team_id: "team_list_tasks_7107",
        linear_team_key: "P7107",
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
        clone_path: "/tmp/repos/list-tasks-7108",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    {:ok, %Task{id: id1}} =
      Pipeline.update_task(system_scope(), task.id, %{
        title: "P1 Task"
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_list_tasks_7106",
      "identifier" => "TSK-7106",
      "title" => "P2 Task"
    })

    {:ok, issue_7106} = Issues.capture_issue(system_scope(), p2, "P2 Task")

    LinearMock.mock_update_issue_success(%{"id" => "lin_task_list_tasks_7106"})

    {:ok, %Task{id: id2}} = Pipeline.create_task(issue_7106)

    system_scope = Scope.for_system()
    user_scope = Scope.for_user(%{admin: false})

    all_tasks_system = Pipeline.list_tasks(system_scope, nil)
    all_ids_system = Enum.map(all_tasks_system, & &1.id)
    assert id1 in all_ids_system
    assert id2 in all_ids_system

    all_tasks_user = Pipeline.list_tasks(user_scope, nil)
    all_ids_user = Enum.map(all_tasks_user, & &1.id)
    assert id1 in all_ids_user
    assert id2 in all_ids_user
  end

  test "supports preload option", %{project: %Project{id: expected_project_id}, task: task} do
    {:ok, %Task{id: id1}} =
      Pipeline.update_task(system_scope(), task.id, %{
        title: "Preload Task"
      })

    scope = Scope.for_system()

    assert [%Task{id: ^id1, project: %Project{id: ^expected_project_id}}] =
             Pipeline.list_tasks(scope, expected_project_id, preload: [:project])
  end
end
