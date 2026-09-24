defmodule Rail.Tools.Actions.GetBrowserUrlTest do
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
            "issue" => %{"id" => "lin_bur_1", "identifier" => "BUR-1", "title" => "Browser Url"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "Browser Url"})
    {:ok, task} = Pipeline.create_task(issue, :qa)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    %{task: task}
  end

  # The panel asks on every render, including for a pass that ended weeks ago, so
  # no browser is the ordinary case rather than an error.
  test "a task with no browser is nowhere", %{task: task} do
    assert Tools.get_browser_url(task) == nil
  end
end
