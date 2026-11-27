defmodule Rail.Git.Actions.WorktreeDirtyTest do
  use Rail.DataCase, async: true

  alias Rail.Git

  test "a freshly committed worktree is clean" do
    repo = create_temp_git_repo()

    refute Git.worktree_dirty?(repo)
  end

  test "a modified tracked file makes it dirty" do
    repo = create_temp_git_repo()
    File.write!(Path.join(repo, "tracked.txt"), "two\n")

    assert Git.worktree_dirty?(repo)
  end

  test "an untracked file makes it dirty" do
    repo = create_temp_git_repo()
    File.write!(Path.join(repo, "untracked.txt"), "wip\n")

    assert Git.worktree_dirty?(repo)
  end

  test "a file under .rail does, like any other" do
    repo = create_temp_git_repo()
    File.mkdir_p!(Path.join(repo, ".rail"))
    File.write!(Path.join(repo, ".rail/settings.json"), "{}\n")

    assert Git.worktree_dirty?(repo)
  end

  # The checkout's .git is the sandbox's to write, and a plain `git status` runs the fsmonitor it names first.
  test "runs no fsmonitor a checkout names" do
    repo = create_temp_git_repo()
    ran = Path.join(repo, "fsmonitor-ran")
    git!(repo, ["config", "core.fsmonitor", "touch #{ran}; false"])
    File.write!(Path.join(repo, "tracked.txt"), "two\n")

    assert Git.worktree_dirty?(repo)
    refute File.exists?(ran)

    System.cmd("git", ["status", "--porcelain"], cd: repo, stderr_to_stdout: true, env: [])
    assert File.exists?(ran)
  end

  test "a path that is not a repository is not dirty" do
    loose = Path.join(System.tmp_dir!(), "not_a_repo_#{System.unique_integer([:positive])}")
    File.mkdir_p!(loose)
    on_exit(fn -> File.rm_rf(loose) end)

    refute Git.worktree_dirty?(loose)
  end
end
