defmodule Rail.Git.Actions.GetOrCreateWorktreeTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project

  test "returns immediately if worktree_path already exists" do
    repo = create_temp_git_repo()
    wt_path = Path.join(repo, ".worktrees/existing")
    File.mkdir_p!(wt_path)

    assert {:ok, ^wt_path} =
             Git.get_or_create_worktree(
               %Project{clone_path: repo, default_branch: "main"},
               %Task{worktree_path: wt_path, worktree_name: "feature-existing"}
             )
  end

  test "creates new worktree with new branch from the project default branch" do
    repo = create_temp_git_repo()
    wt_path = Path.join(repo, ".worktrees/feature-1")

    assert {:ok, ^wt_path} =
             Git.get_or_create_worktree(
               %Project{clone_path: repo, default_branch: "main"},
               %Task{worktree_path: wt_path, worktree_name: "feature-1"}
             )

    assert File.dir?(wt_path)
    assert File.exists?(Path.join(wt_path, "tracked.txt"))
  end

  test "checks out existing branch if branch already exists in repo" do
    repo = create_temp_git_repo()
    git!(repo, ["branch", "pre-existing-branch"])

    wt_path = Path.join(repo, ".worktrees/feature-pre")

    assert {:ok, ^wt_path} =
             Git.get_or_create_worktree(
               %Project{clone_path: repo, default_branch: "main"},
               %Task{worktree_path: wt_path, worktree_name: "pre-existing-branch"}
             )

    assert File.dir?(wt_path)
  end

  test "errors when the project default branch does not exist" do
    repo = create_temp_git_repo(branch: "primary")
    wt_path = Path.join(repo, ".worktrees/feature-missing-base")

    # the project's default_branch is "main", which does not exist in this repo
    assert {:error, reason} =
             Git.get_or_create_worktree(
               %Project{clone_path: repo, default_branch: "main"},
               %Task{worktree_path: wt_path, worktree_name: "feature-missing-base"}
             )

    assert String.contains?(reason, "Failed to create worktree")
    refute File.dir?(wt_path)
  end

  test "creates new worktree from the project's non-main default branch" do
    repo = create_temp_git_repo(branch: "develop")
    wt_path = Path.join(repo, ".worktrees/feature-from-dev")

    assert {:ok, ^wt_path} =
             Git.get_or_create_worktree(
               %Project{clone_path: repo, default_branch: "develop"},
               %Task{worktree_path: wt_path, worktree_name: "feature-from-dev"}
             )

    assert File.dir?(wt_path)
  end

  test "derives the worktree path from the clone path when the task has none" do
    repo = create_temp_git_repo()
    project = %Project{clone_path: repo, default_branch: "main"}
    task = %Task{id: "tsk_derived", worktree_name: "feature-derived"}

    expected = Path.join(repo, ".worktrees/feature-derived")
    assert {:ok, ^expected} = Git.get_or_create_worktree(project, task)
    assert File.dir?(expected)
  end

  test "falls back to the task id when the task has no worktree name" do
    repo = create_temp_git_repo()
    project = %Project{clone_path: repo, default_branch: "main"}
    task = %Task{id: "tsk_by_id"}

    expected = Path.join(repo, ".worktrees/tsk_by_id")
    assert {:ok, ^expected} = Git.get_or_create_worktree(project, task)
    assert File.dir?(expected)
  end

  test "returns error if all attempts fail" do
    # Non-git directory
    temp_dir = System.tmp_dir!()
    fake_repo = Path.join(temp_dir, "not_a_repo_#{System.unique_integer([:positive])}")
    File.mkdir_p!(fake_repo)
    on_exit(fn -> File.rm_rf(fake_repo) end)

    wt_path = Path.join(fake_repo, ".worktrees/fail")

    assert {:error, reason} =
             Git.get_or_create_worktree(
               %Project{clone_path: fake_repo, default_branch: "main"},
               %Task{worktree_path: wt_path, worktree_name: "fail-branch"}
             )

    assert String.contains?(reason, "Failed to create worktree")
  end
end
