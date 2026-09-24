defmodule Rail.Pipeline.Actions.GetImplementationPlanTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.ImplementationPlan

  setup %{project: project} do
    scope = system_scope()

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_get_plan_1", "identifier" => "GTP-1", "title" => "Get Plan"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "Get Plan"})
    {:ok, task} = Pipeline.create_task(issue, :architect)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    %{task: task}
  end

  test "returns the approved plan", %{task: task} do
    %ImplementationPlan{}
    |> ImplementationPlan.changeset(%{
      task_id: task.id,
      content: "## Implementation plan",
      captured_at: DateTime.utc_now()
    })
    |> Repo.insert!()

    assert {:ok, %ImplementationPlan{content: "## Implementation plan"}} =
             Pipeline.get_implementation_plan(task)
  end

  test "a task whose plan nobody approved has none", %{task: task} do
    assert {:error, :not_found} = Pipeline.get_implementation_plan(task)
  end
end
