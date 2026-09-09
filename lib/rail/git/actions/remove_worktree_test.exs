defmodule Rail.Git.Actions.RemoveWorktreeTest do
  use Rail.DataCase, async: true

  alias Rail.Git

  test "removes an existing worktree successfully" do
    repo = create_temp_git_repo()
    wt_path = Path.join(repo, ".worktrees/to_remove")
    assert {:ok, ^wt_path} = Git.get_or_create_worktree(repo, wt_path, "feature-remove")
    assert File.dir?(wt_path)

    assert :ok = Git.remove_worktree(repo, wt_path)
    refute File.dir?(wt_path)
  end

  test "returns :ok even if worktree directory is already gone" do
    repo = create_temp_git_repo()
    wt_path = Path.join(repo, ".worktrees/nonexistent")

    assert :ok = Git.remove_worktree(repo, wt_path)
  end

  test "returns error if worktree remove fails and directory still exists" do
    # Create directory that git cannot remove (e.g. not a real worktree in git's eyes)
    repo = create_temp_git_repo()
    locked_dir = Path.join(repo, ".worktrees/unregistered_dir")
    File.mkdir_p!(locked_dir)
    File.write!(Path.join(locked_dir, "file.txt"), "content")

    assert {:error, reason} = Git.remove_worktree(repo, locked_dir)
    assert byte_size(reason) > 0
  end
end
