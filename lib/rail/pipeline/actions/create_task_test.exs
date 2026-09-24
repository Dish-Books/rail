defmodule Rail.Pipeline.Actions.CreateTaskTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task

  setup %{project: project} do
    scope = system_scope()

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_create_task_1",
              "identifier" => "CRT-1",
              "title" => "Create Task Issue"
            }
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "Create Task Issue"})

    %{issue: issue}
  end

  test "names the worktree after the issue's identifier", %{issue: %Issue{id: issue_id} = issue} do
    path = "/tmp/repos/test-seed/.worktrees/crt-1"

    assert {:ok, %Task{issue_id: ^issue_id, stage: :product, worktree_name: "crt-1", worktree_path: ^path}} =
             Pipeline.create_task(issue, :product)
  end

  test "names the worktree after the issue's branch when it has one", %{issue: issue} do
    issue = issue |> Issue.linear_changeset(%{branch_name: "michael/crt-1-fix"}) |> Repo.update!()

    assert {:ok, %Task{worktree_name: "michael/crt-1-fix"}} = Pipeline.create_task(issue, :engineer)
  end

  test "returns the task an issue already has", %{issue: issue} do
    {:ok, %Task{id: task_id}} = Pipeline.create_task(issue, :product)

    assert {:ok, %Task{id: ^task_id, stage: :product}} = Pipeline.create_task(issue, :design)
  end
end
