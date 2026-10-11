defmodule Rail.Mcp.Utils.RunToolBrowserCloseTest do
  use Rail.DataCase, async: true

  import Rail.Mcp.Utils.RunToolBrowserClose

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Tools.Schemas.BrowserSession

  setup %{project: project} do
    Req.Test.expect(Rail.Linear, fn conn ->
      n = System.unique_integer([:positive])

      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_bcl_#{n}", "identifier" => "BCL-#{n}", "title" => "Close Browsers"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Close Browsers"})
    {:ok, task} = Pipeline.create_task(issue, :review)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    for name <- ["explorer-1", "explorer-2"] do
      %BrowserSession{}
      |> BrowserSession.changeset(%{task_id: task.id, name: name, status: :running})
      |> Repo.insert!()
    end

    %{task: task}
  end

  # An explorer working in the background is never seen to finish, so its saying it
  # is done is what gives its place to the next one waiting.
  test "closes the browser it names and leaves the task's others open", %{task: task} do
    assert {:ok, "Closed `explorer-1`." <> _rest} =
             run_tool_browser_close(task, %{"browser" => "explorer-1"}, stage: :review_lead)

    assert [
             %BrowserSession{name: "explorer-1", status: :finished, ended_reason: :closed, finished_at: %DateTime{}},
             %BrowserSession{name: "explorer-2", status: :running}
           ] = Repo.all(from s in BrowserSession, where: s.task_id == ^task.id, order_by: s.name)
  end

  # A slip in the name would otherwise read as done while the browser meant stays open.
  test "a name nothing is open under is refused, and one already closed is too", %{task: task} do
    assert {:refused, "No browser named `typo` is open on this task" <> _rest} =
             run_tool_browser_close(task, %{"browser" => "typo"}, stage: :review_lead)

    assert {:ok, _closed} = run_tool_browser_close(task, %{"browser" => "explorer-2"}, stage: :review_lead)

    assert {:refused, "No browser named `explorer-2` is open" <> _rest} =
             run_tool_browser_close(task, %{"browser" => "explorer-2"}, stage: :review_lead)
  end

  test "a call from the Review lead's run that names no browser closes nothing", %{task: task} do
    assert {:refused, "Pass `browser`, the name the lead gave you" <> _rest} =
             run_tool_browser_close(task, %{}, stage: :review_lead)

    assert [%BrowserSession{status: :running}, %BrowserSession{status: :running}] =
             Repo.all(from s in BrowserSession, where: s.task_id == ^task.id)
  end
end
