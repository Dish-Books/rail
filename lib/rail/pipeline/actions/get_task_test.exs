defmodule Rail.Pipeline.Actions.GetTaskTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles

  setup %{project: project} do
    scope = system_scope()

    {:ok, backend} = Rail.Tools.create_backend(scope, %{name: :claude, executable_path: "/usr/bin/true"})

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_get_task_1",
              "identifier" => "GTK-1",
              "title" => "Get Task Issue"
            }
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Get Task Issue"})

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
