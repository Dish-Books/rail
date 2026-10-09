defmodule Rail.Tools.Actions.ListBrowserSessionsTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Tools
  alias Rail.Tools.Schemas.BrowserSession

  setup %{project: project} do
    Req.Test.expect(Rail.Linear, 2, fn conn ->
      n = System.unique_integer([:positive])

      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_lbs_#{n}", "identifier" => "LBS-#{n}", "title" => "List Browsers"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "List Browsers"})
    {:ok, task} = Pipeline.create_task(issue, :review)
    {:ok, other_issue} = Issues.create_issue(system_scope(), project, %{description: "Other Browsers"})
    {:ok, other} = Pipeline.create_task(other_issue, :review)

    on_exit(fn ->
      File.rm_rf(task.scratch_path)
      File.rm_rf(other.scratch_path)
    end)

    %{task: task, other: other}
  end

  test "lists only the task's live sessions, with their name and account, oldest first", %{task: task, other: other} do
    now = DateTime.utc_now()

    %BrowserSession{id: later} =
      %BrowserSession{}
      |> BrowserSession.changeset(%{
        task_id: task.id,
        name: "explorer-2",
        account: "explorer-2@rail.test",
        status: :running,
        started_at: DateTime.shift(now, second: 1)
      })
      |> Repo.insert!()

    %BrowserSession{id: earlier} =
      %BrowserSession{}
      |> BrowserSession.changeset(%{task_id: task.id, name: "explorer-1", status: :starting, started_at: now})
      |> Repo.insert!()

    %BrowserSession{}
    |> BrowserSession.changeset(%{
      task_id: task.id,
      name: "demo",
      status: :finished,
      started_at: DateTime.shift(now, second: -1),
      finished_at: now
    })
    |> Repo.insert!()

    %BrowserSession{}
    |> BrowserSession.changeset(%{task_id: other.id, name: "explorer-1", status: :running, started_at: now})
    |> Repo.insert!()

    assert [
             %BrowserSession{id: ^earlier, name: "explorer-1", account: nil, status: :starting},
             %BrowserSession{id: ^later, name: "explorer-2", account: "explorer-2@rail.test", status: :running}
           ] = Tools.list_browser_sessions(task)
  end

  # Two sessions opened in the same instant still come back in the same order every time.
  test "the id breaks a tie between sessions started and saved at the same moment", %{task: task} do
    now = DateTime.utc_now()

    ids =
      for name <- ["explorer-1", "explorer-2"] do
        %BrowserSession{id: id} =
          %BrowserSession{inserted_at: now, updated_at: now}
          |> BrowserSession.changeset(%{task_id: task.id, name: name, status: :running, started_at: now})
          |> Repo.insert!()

        id
      end

    [first, second] = Enum.sort(ids)

    assert [%BrowserSession{id: ^first}, %BrowserSession{id: ^second}] = Tools.list_browser_sessions(task)
  end

  test "a task with no browser lists none", %{task: task} do
    assert Tools.list_browser_sessions(task) == []
  end
end
