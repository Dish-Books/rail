defmodule Rail.Pipeline.Actions.CreateRoundTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Round
  alias Rail.Pipeline.Schemas.Task

  setup %{project: project} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_create_round_1", "identifier" => "CRR-1", "title" => "Rounds"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Rounds"})
    {:ok, task} = Pipeline.create_task(issue, :plan)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    %{task: task}
  end

  test "a task's first round is round 1, with no plan yet", %{task: %Task{id: task_id} = task} do
    assert {:ok, %Round{task_id: ^task_id, number: 1, plan: nil, plan_version: 0, record_demo: false}} =
             Pipeline.create_round(task)
  end

  test "each round after it is numbered one past the latest", %{task: task} do
    {:ok, _first} = Pipeline.create_round(task)
    {:ok, _second} = Pipeline.create_round(task)

    assert {:ok, %Round{number: 3}} = Pipeline.create_round(task)
  end
end
