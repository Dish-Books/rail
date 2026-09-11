defmodule Rail.Pipeline.Actions.ExpandDiffGapTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Projects
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    scope = system_scope()

    {:ok, workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Expand Diff Workspace",
        external_id: "lin_ws_expand_diff",
        token: "lin_api_token_expand_diff",
        webhook_secret: "whsec_expand_diff"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Expand Diff Project 7301",
        github_repo: "org/expand-diff-7301",
        github_installation_id: 7301,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_expand_diff_7301",
        linear_team_key: "P7301",
        clone_path: "/tmp/repos/expand-diff-7301",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_expand_diff_1",
      "identifier" => "EDG-1",
      "title" => "Expand Diff Issue"
    })

    {:ok, issue} = Issues.capture_issue(scope, project, "Expand Diff Issue")

    {:ok, task} = Pipeline.create_task(issue, :product)

    %{project: project, issue: issue, task: task}
  end

  test "slices lines from start_line to end_line from disk when diff_rev is nil", %{task: task} do
    repo = create_temp_git_repo()
    content = Enum.map_join(1..20, "\n", fn i -> "line #{i}" end) <> "\n"
    File.write!(Path.join(repo, "sample.txt"), content)

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        worktree_path: repo
      })

    assert {"sample.txt:0", ["line 5", "line 6", "line 7"]} =
             Pipeline.expand_diff_gap(task, "sample.txt", 0, 5, 7, nil)
  end

  test "reads lines from git rev HEAD when diff_rev is provided", %{task: task} do
    repo = create_temp_git_repo()
    content = Enum.map_join(1..10, "\n", fn i -> "rev line #{i}" end) <> "\n"
    File.write!(Path.join(repo, "committed.txt"), content)
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "add committed"])

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        worktree_path: repo
      })

    assert {"committed.txt:1", ["rev line 2", "rev line 3"]} =
             Pipeline.expand_diff_gap(task, "committed.txt", 1, 2, 3, "HEAD")
  end

  test "returns empty list when file lines cannot be read or file does not exist", %{task: task} do
    repo = create_temp_git_repo()

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        worktree_path: repo
      })

    assert {"missing.txt:0", []} =
             Pipeline.expand_diff_gap(task, "missing.txt", 0, 1, 5, nil)
  end

  test "returns empty list when worktree_path is nil", %{task: task} do
    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        worktree_path: "/tmp/rail-removed-worktree"
      })

    assert {"any.txt:0", []} =
             Pipeline.expand_diff_gap(task, "any.txt", 0, 1, 5, nil)
  end
end
