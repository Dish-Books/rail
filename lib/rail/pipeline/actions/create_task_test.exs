defmodule Rail.Pipeline.Actions.CreateTaskTest do
  use Rail.DataCase, async: true

  import Ecto.Query

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task

  setup %{project: project} do
    scope = system_scope()

    {:ok, issue} = Issues.create_issue(scope, project, %{title: "Issue", description: "Create Task Issue"})

    %{issue: issue}
  end

  test "puts the task's own clone under the tasks root, named after the issue's identifier", %{project: project} do
    %Issue{id: issue_id} =
      issue =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project.id,
        identifier: "CRT-1",
        title: "Issue",
        state: :triage
      })
      |> Repo.insert!()
      |> Repo.preload(:project)

    path = Path.join([Rail.tasks_root(), project.id, "crt-1", "repo"])

    assert {:ok, %Task{issue_id: ^issue_id, stage: :plan, worktree_name: "crt-1", worktree_path: ^path}} =
             Pipeline.create_task(issue, :plan)
  end

  test "names the worktree after the issue's branch when it has one", %{issue: issue} do
    issue = issue |> Issue.tracker_changeset(%{branch_name: "michael/crt-1-fix"}) |> Repo.update!()

    path = Path.join([Rail.tasks_root(), issue.project_id, "michael/crt-1-fix", "repo"])

    assert {:ok, %Task{worktree_name: "michael/crt-1-fix", worktree_path: ^path}} =
             Pipeline.create_task(issue, :engineer)
  end

  test "refuses an issue that already has a live task", %{issue: issue} do
    {:ok, %Task{id: task_id}} = Pipeline.create_task(issue, :plan)

    assert {:error, :task_exists} = Pipeline.create_task(issue, :plan)
    assert [%Task{id: ^task_id}] = Repo.all(from t in Task, where: t.issue_id == ^issue.id)
  end
end
