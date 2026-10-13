defmodule Rail.Pipeline.Actions.GetCurrentRoundTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Round

  setup %{project: project} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_get_current_round_1", "identifier" => "GCR-1", "title" => "Rounds"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Rounds"})
    {:ok, task} = Pipeline.create_task(issue, :plan)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    %{task: task}
  end

  test "returns the task's latest round", %{task: task} do
    {:ok, _first} = Pipeline.create_round(task)
    {:ok, _second} = Pipeline.create_round(task)

    assert {:ok, %Round{number: 2}} = Pipeline.get_current_round(task)
  end

  test "a task that has not started has none", %{task: task} do
    assert {:error, :not_found} = Pipeline.get_current_round(task)
  end
end
