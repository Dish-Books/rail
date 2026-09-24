defmodule Rail.Tools.Actions.GetBrowserFrameTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Tools

  setup %{project: project} do
    scope = system_scope()

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_bfr_1", "identifier" => "BFR-1", "title" => "Browser Frame"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "Browser Frame"})
    {:ok, task} = Pipeline.create_task(issue, :qa)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    %{task: task}
  end

  # Every QA panel asks for this on the way in, including the ones opened long
  # after the pass ended, so no browser is the ordinary case rather than an error.
  test "a task with no browser has nothing to show", %{task: task} do
    assert Tools.get_browser_frame(task) == nil
  end
end
