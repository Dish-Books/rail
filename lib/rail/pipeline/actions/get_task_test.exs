defmodule Rail.Pipeline.Actions.GetTaskTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Roles
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    scope = system_scope()

    {:ok, backend} = Rail.Tools.create_backend(scope, %{name: :claude, executable_path: "/usr/bin/true"})

    {:ok, project} =
      Projects.create_project(scope, %{
        name: "Get Task Project",
        github_repo: "org/get-task",
        github_installation_id: 6401,
        linear_workspace: %{
          name: "Get Task Workspace",
          external_id: "lin_ws_get_task",
          token: "lin_api_token_get_task",
          webhook_secret: "whsec_get_task"
        },
        linear_team_id: "team_get_task",
        linear_team_key: "GTK",
        default_branch: "main",
        clone_path: "/tmp/repos/get-task",
        linear_state_ids: %{"triage" => "st_triage", "in_progress" => "st_in_progress"}
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_get_task_1",
      "identifier" => "GTK-1",
      "title" => "Get Task Issue"
    })

    {:ok, issue} = Issues.create_issue(project, %{description: "Get Task Issue"})

    {:ok, task} = Pipeline.create_task(issue, :product)

    %{backend: backend, project: project, issue: issue, task: task}
  end

  test "reports not_found when the task does not exist" do
    assert {:error, :not_found} = Pipeline.get_task("tsk_000000000000000000000000")
  end

  test "loads the project, the issue and the runs with their roles", %{
    backend: backend,
    project: %{id: project_id} = project,
    issue: %{id: issue_id},
    task: %Task{id: task_id} = task
  } do
    {:ok, role} =
      Roles.create_role(system_scope(), project, %{
        backend_id: backend.id,
        stage: :product,
        name: "product role",
        model: "claude-3-7-sonnet",
        system_prompt: "You are the product agent."
      })

    {:ok, %Run{id: run_id}} =
      Pipeline.create_run(%{task_id: task.id, role_id: role.id, status: :running, started_at: DateTime.utc_now()})

    assert {:ok,
            %Task{
              id: ^task_id,
              project: %{id: ^project_id},
              issue: %{id: ^issue_id},
              runs: [%Run{id: ^run_id, role: %{stage: :product}}]
            }} = Pipeline.get_task(task.id)
  end

  test "does not load artifacts: a page asks for what it draws", %{task: task} do
    assert {:ok, loaded} = Pipeline.get_task(task.id)
    refute Map.has_key?(loaded, :design)
    refute Map.has_key?(loaded, :demo)
  end
end
