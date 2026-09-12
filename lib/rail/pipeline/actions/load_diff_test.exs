defmodule Rail.Pipeline.Actions.LoadDiffTest do
  use Rail.DataCase, async: true

  alias Rail.Domain.Diff.FileDiff
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Projects
  alias Rail.Scope
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    scope = system_scope()

    {:ok, workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Load Diff Workspace",
        external_id: "lin_ws_load_diff",
        token: "lin_api_token_load_diff",
        webhook_secret: "whsec_load_diff"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Load Diff Project 7401",
        github_repo: "org/load-diff-7401",
        github_installation_id: 7401,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_load_diff_7401",
        linear_team_key: "P7401",
        default_branch: "main",
        clone_path: "/tmp/repos/load-diff-7401",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_load_diff_1",
      "identifier" => "LDF-1",
      "title" => "Load Diff Issue"
    })

    {:ok, issue} = Issues.capture_issue(scope, project, "Load Diff Issue")

    {:ok, task} = Pipeline.create_task(issue, :product)

    %{project: project, issue: issue, task: task}
  end

  test "returns {:error, :no_worktree} when task worktree_path is nil", %{task: task} do
    {:ok, task} =
      Pipeline.update_task(task, %{
        worktree_path: "/tmp/rail-removed-worktree"
      })

    assert {:error, :no_worktree} = Pipeline.load_diff(task)
    assert {:error, :no_worktree} = Pipeline.load_diff(task)
  end

  test "loads branch changes against main with diff_rev HEAD and reconciles viewed files", %{task: task} do
    repo = create_temp_git_repo()
    git!(repo, ["checkout", "-b", "feature-work"])

    File.write!(Path.join(repo, "feature.txt"), "feature line\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "commit feature"])

    {:ok, task} =
      Pipeline.update_task(task, %{
        worktree_path: repo,
        viewed_diff_files: %{"stale.txt" => "old_digest"}
      })

    assert {:ok, [file | _rest] = files, "HEAD"} = Pipeline.load_diff(task)
    assert %FileDiff{path: "feature.txt"} = file

    # Reconciled task in DB has stale viewed mark removed
    reloaded_task = Pipeline.get_task(task.id)
    assert reloaded_task.viewed_diff_files == %{}

    # Pipeline delegate with scope also works
    assert {:ok, ^files, "HEAD"} = Pipeline.load_diff(task)
  end

  test "loads uncommitted changes with diff_rev nil when no branch commits against main", %{task: task} do
    repo = create_temp_git_repo()
    File.write!(Path.join(repo, "uncommitted.txt"), "uncommitted work\n")

    {:ok, task} =
      Pipeline.update_task(task, %{
        worktree_path: repo,
        viewed_diff_files: %{}
      })

    assert {:ok, [file | _rest], nil} = Pipeline.load_diff(task)
    assert %FileDiff{path: "uncommitted.txt"} = file
  end
end
