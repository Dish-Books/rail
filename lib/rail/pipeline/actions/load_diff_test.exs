defmodule Rail.Pipeline.Actions.LoadDiffTest do
  use Rail.DataCase, async: true

  alias Rail.Domain.Diff.FileDiff
  alias Rail.Pipeline
  alias Rail.Scope

  test "returns {:error, :no_worktree} when task worktree_path is nil" do
    task = create_test_task(%{worktree_path: nil})

    assert {:error, :no_worktree} = Pipeline.load_diff(task)
    assert {:error, :no_worktree} = Pipeline.load_diff(Scope.for_system(), task)
  end

  test "loads branch changes against main with diff_rev HEAD and reconciles viewed files" do
    repo = create_temp_git_repo()
    git!(repo, ["checkout", "-b", "feature-work"])

    File.write!(Path.join(repo, "feature.txt"), "feature line\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "commit feature"])

    task =
      create_test_task(%{
        worktree_path: repo,
        viewed_diff_files: %{"stale.txt" => "old_digest"}
      })

    assert {:ok, [file | _rest] = files, "HEAD"} = Pipeline.load_diff(task)
    assert %FileDiff{path: "feature.txt"} = file

    # Reconciled task in DB has stale viewed mark removed
    reloaded_task = Pipeline.get_task!(Scope.for_system(), task.id)
    assert reloaded_task.viewed_diff_files == %{}

    # Pipeline delegate with scope also works
    assert {:ok, ^files, "HEAD"} = Pipeline.load_diff(Scope.for_system(), task)
  end

  test "loads uncommitted changes with diff_rev nil when no branch commits against main" do
    repo = create_temp_git_repo()
    File.write!(Path.join(repo, "uncommitted.txt"), "uncommitted work\n")

    task = create_test_task(%{worktree_path: repo, viewed_diff_files: %{}})

    assert {:ok, [file | _rest], nil} = Pipeline.load_diff(task)
    assert %FileDiff{path: "uncommitted.txt"} = file
  end
end
