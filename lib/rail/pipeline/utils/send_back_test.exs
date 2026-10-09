defmodule Rail.Pipeline.Utils.SendBackTest do
  use Rail.DataCase, async: true

  import Rail.Pipeline.Utils.SendBack

  alias Rail.Issues
  alias Rail.Pipeline

  setup %{project: project} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_sbk_1", "identifier" => "SBK-1", "title" => "Send Back"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Send Back"})
    {:ok, task} = Pipeline.create_task(issue, :review)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    %{task: task}
  end

  test "a stage that has never run is told nothing, since its brief is its first turn", %{task: task} do
    assert :ok = send_back(task, :review_lead, "Start fix round 1.")
  end
end
