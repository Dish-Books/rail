defmodule Rail.Git.Actions.BaseStatusTest do
  use ExUnit.Case, async: true

  import RailTest.Helpers

  alias Rail.Git

  setup do
    repo = create_temp_git_repo()
    File.write!(Path.join(repo, "shared.ex"), "one\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "the base"])
    git!(repo, ["update-ref", "refs/remotes/origin/main", "HEAD"])
    %{repo: repo}
  end

  test "a branch with the default branch in its history is not behind, ahead of it or not", %{repo: repo} do
    assert %{behind: false, conflicts: []} = Git.base_status(repo, "main")

    git!(repo, ["commit", "--allow-empty", "-m", "the work"])
    assert %{behind: false, conflicts: []} = Git.base_status(repo, "main")
  end

  test "a branch behind it that merges cleanly is behind with nothing in conflict", %{repo: repo} do
    git!(repo, ["checkout", "-q", "-b", "landing"])
    File.write!(Path.join(repo, "other.ex"), "landed\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-qm", "landed on main"])
    git!(repo, ["update-ref", "refs/remotes/origin/main", "HEAD"])
    git!(repo, ["checkout", "-q", "-"])

    assert %{behind: true, conflicts: []} = Git.base_status(repo, "main")
  end

  test "a branch behind it that changed the same lines conflicts in that file", %{repo: repo} do
    git!(repo, ["checkout", "-q", "-b", "landing"])
    File.write!(Path.join(repo, "shared.ex"), "theirs\n")
    git!(repo, ["commit", "-qam", "landed on main"])
    git!(repo, ["update-ref", "refs/remotes/origin/main", "HEAD"])
    git!(repo, ["checkout", "-q", "-"])
    File.write!(Path.join(repo, "shared.ex"), "ours\n")
    git!(repo, ["commit", "-qam", "the work"])

    assert %{behind: true, conflicts: ["shared.ex"]} = Git.base_status(repo, "main")
    # Worked out without a checkout, so the worktree is as the agent left it.
    assert File.read!(Path.join(repo, "shared.ex")) == "ours\n"
  end

  test "a default branch git cannot read counts as up to date", %{repo: repo} do
    assert %{behind: false, conflicts: []} = Git.base_status(repo, "trunk")
  end
end
