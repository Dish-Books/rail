defmodule Rail.Git.Actions.GetDiffTest do
  use Rail.DataCase, async: true

  alias Rail.Git

  test "returns tracked uncommitted changes and synthesizes untracked files when filter is nil" do
    repo = create_temp_git_repo()
    File.write!(Path.join(repo, "tracked.txt"), "one\ntwo\n")
    File.write!(Path.join(repo, "untracked.txt"), "hello untracked\n")

    diff = Git.get_diff(repo)

    assert String.contains?(diff, "diff --git a/tracked.txt b/tracked.txt")
    assert String.contains?(diff, "+two")
    assert String.contains?(diff, "diff --git a/untracked.txt b/untracked.txt")
    assert String.contains?(diff, "+hello untracked")
  end

  test "returns tracked uncommitted changes when filter is uncommitted" do
    repo = create_temp_git_repo()
    File.write!(Path.join(repo, "tracked.txt"), "one\ntwo\n")
    File.write!(Path.join(repo, "untracked.txt"), "untracked file\n")

    diff = Git.get_diff(repo, "uncommitted")

    assert String.contains?(diff, "diff --git a/tracked.txt b/tracked.txt")
    assert String.contains?(diff, "+two")
    assert String.contains?(diff, "diff --git a/untracked.txt b/untracked.txt")
  end

  test "returns branch diff against main when filter is main" do
    repo = create_temp_git_repo()
    git!(repo, ["checkout", "-b", "feature-branch"])

    File.write!(Path.join(repo, "feature.txt"), "branch work\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "feature commit"])

    diff = Git.get_diff(repo, "main")

    assert String.contains?(diff, "diff --git a/feature.txt b/feature.txt")
    assert String.contains?(diff, "+branch work")
  end

  test "returns commit range diff when custom filter is provided" do
    repo = create_temp_git_repo()
    File.write!(Path.join(repo, "second.txt"), "second\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "second commit"])

    diff = Git.get_diff(repo, "HEAD~1..HEAD")

    assert String.contains?(diff, "diff --git a/second.txt b/second.txt")
    assert String.contains?(diff, "+second")
  end

  test "falls back to bare git diff on error" do
    repo = create_temp_git_repo()
    File.write!(Path.join(repo, "tracked.txt"), "modified\n")

    # Asking for a non-existent commit or branch triggers fallback
    diff = Git.get_diff(repo, "non_existent_branch_123")

    assert String.contains?(diff, "diff --git a/tracked.txt b/tracked.txt")
  end

  test "accepts keyword options and atom filter for main and uncommitted" do
    repo = create_temp_git_repo()
    git!(repo, ["checkout", "-b", "feat-branch"])
    File.write!(Path.join(repo, "feat.txt"), "feat\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "feat commit"])

    diff_main = Git.get_diff(repo, filter: :main)
    assert String.contains?(diff_main, "diff --git a/feat.txt b/feat.txt")

    File.write!(Path.join(repo, "dirty.txt"), "dirty line\n")
    diff_uncommitted = Git.get_diff(repo, filter: :uncommitted)
    assert String.contains?(diff_uncommitted, "diff --git a/dirty.txt b/dirty.txt")

    File.write!(Path.join(repo, "feat.txt"), "modified feat\n")
    diff_atom = Git.get_diff(repo, :HEAD)
    assert String.contains?(diff_atom, "diff --git a/feat.txt b/feat.txt")

    diff_other = Git.get_diff(repo, 12_345)
    assert String.contains?(diff_other, "diff --git a/dirty.txt b/dirty.txt")
  end
end
