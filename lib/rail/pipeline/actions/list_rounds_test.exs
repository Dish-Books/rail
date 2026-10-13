defmodule Rail.Pipeline.Actions.ListRoundsTest do
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
            "issue" => %{"id" => "lin_list_rounds_1", "identifier" => "LSR-1", "title" => "Rounds"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Rounds"})
    {:ok, task} = Pipeline.create_task(issue, :plan)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    %{task: task}
  end

  test "lists a task's rounds oldest first", %{task: task} do
    {:ok, _first} = Pipeline.create_round(task)
    {:ok, _second} = Pipeline.create_round(task)

    assert [%Round{number: 1}, %Round{number: 2}] = Pipeline.list_rounds(task)
  end

  test "a task that has not started has none", %{task: task} do
    assert [] = Pipeline.list_rounds(task)
  end
end
