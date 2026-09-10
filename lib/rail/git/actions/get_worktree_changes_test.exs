defmodule Rail.Git.Actions.GetWorktreeChangesTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Git.WorktreeChanges

  test "counts committed work on the branch against main" do
    repo = create_temp_git_repo()
    git!(repo, ["checkout", "-b", "rail/feature"])

    File.write!(Path.join(repo, "added.txt"), "a\nb\nc\n")
    File.write!(Path.join(repo, "tracked.txt"), "one\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "feature slice"])

    changes = Git.get_worktree_changes(repo)

    assert changes.filter == "main"
    assert WorktreeChanges.additions(changes) == 3
    assert WorktreeChanges.deletions(changes) == 0
    refute WorktreeChanges.empty?(changes)
  end

  test "falls back to uncommitted working tree before first commit" do
    repo = create_temp_git_repo()
    git!(repo, ["checkout", "-b", "rail/wip"])

    File.write!(Path.join(repo, "wip.txt"), "line1\nline2\n")

    changes = Git.get_worktree_changes(repo)

    assert changes.filter == "uncommitted"
    assert WorktreeChanges.additions(changes) == 2
  end

  test "a branch with no changes reads as empty" do
    repo = create_temp_git_repo()
    git!(repo, ["checkout", "-b", "rail/clean"])

    changes = Git.get_worktree_changes(repo)

    assert WorktreeChanges.empty?(changes)
    assert WorktreeChanges.additions(changes) == 0
    assert WorktreeChanges.deletions(changes) == 0
  end
end
