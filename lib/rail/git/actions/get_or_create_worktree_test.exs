defmodule Rail.Git.Actions.GetOrCreateWorktreeTest do
  use Rail.DataCase, async: true

  alias Rail.Git

  test "returns immediately if worktree_path already exists" do
    repo = create_temp_git_repo()
    wt_path = Path.join(repo, ".worktrees/existing")
    File.mkdir_p!(wt_path)

    assert {:ok, ^wt_path} = Git.get_or_create_worktree(repo, wt_path, "feature-existing")
  end

  test "creates new worktree with new branch from main" do
    repo = create_temp_git_repo()
    wt_path = Path.join(repo, ".worktrees/feature-1")

    assert {:ok, ^wt_path} = Git.get_or_create_worktree(repo, wt_path, "feature-1")
    assert File.dir?(wt_path)
    assert File.exists?(Path.join(wt_path, "tracked.txt"))
  end

  test "checks out existing branch if branch already exists in repo" do
    repo = create_temp_git_repo()
    git!(repo, ["branch", "pre-existing-branch"])

    wt_path = Path.join(repo, ".worktrees/feature-pre")
    assert {:ok, ^wt_path} = Git.get_or_create_worktree(repo, wt_path, "pre-existing-branch")
    assert File.dir?(wt_path)
  end

  test "falls back to detached HEAD when base branch does not exist" do
    repo = create_temp_git_repo(branch: "primary")
    wt_path = Path.join(repo, ".worktrees/feature-detached")

    # default base_branch is "main", which does not exist in this repo
    assert {:ok, ^wt_path} = Git.get_or_create_worktree(repo, wt_path, "feature-detached")
    assert File.dir?(wt_path)
  end

  test "creates new worktree with explicit base_branch" do
    repo = create_temp_git_repo(branch: "develop")
    wt_path = Path.join(repo, ".worktrees/feature-from-dev")

    assert {:ok, ^wt_path} = Git.get_or_create_worktree(repo, wt_path, "feature-from-dev", base_branch: "develop")
    assert File.dir?(wt_path)
  end

  test "returns error if all attempts fail" do
    # Non-git directory
    temp_dir = System.tmp_dir!()
    fake_repo = Path.join(temp_dir, "not_a_repo_#{System.unique_integer([:positive])}")
    File.mkdir_p!(fake_repo)
    on_exit(fn -> File.rm_rf(fake_repo) end)

    wt_path = Path.join(fake_repo, ".worktrees/fail")
    assert {:error, reason} = Git.get_or_create_worktree(fake_repo, wt_path, "fail-branch")
    assert String.contains?(reason, "Failed to create worktree")
  end
end
