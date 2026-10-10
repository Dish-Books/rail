defmodule Rail.Git.Actions.BranchUnpushedTest do
  use Rail.DataCase, async: true

  alias Rail.Git

  setup do
    remote = create_temp_git_repo(prefix: "rail_unpushed_remote")
    repo = create_temp_git_repo(initial_commit: false)
    git!(repo, ["remote", "add", "origin", remote])
    git!(repo, ["fetch", "--quiet", "origin"])
    git!(repo, ["checkout", "--quiet", "--no-track", "-b", "feature", "origin/main"])

    %{repo: repo}
  end

  test "a fresh branch from the default branch has nothing to push, with no upstream", %{repo: repo} do
    refute Git.branch_unpushed?(repo)
  end

  test "a commit only here is unpushed until it is pushed", %{repo: repo} do
    git!(repo, ["commit", "--allow-empty", "-m", "the work"])
    assert Git.branch_unpushed?(repo)

    git!(repo, ["push", "--quiet", "--set-upstream", "origin", "feature"])
    refute Git.branch_unpushed?(repo)
  end

  test "a branch rewritten since its push is unpushed", %{repo: repo} do
    git!(repo, ["commit", "--allow-empty", "-m", "the work"])
    git!(repo, ["push", "--quiet", "--set-upstream", "origin", "feature"])
    git!(repo, ["commit", "--amend", "--allow-empty", "-m", "the work, reworded"])

    assert Git.branch_unpushed?(repo)
  end

  test "a worktree git cannot read counts as unpushed" do
    assert Git.branch_unpushed?(create_temp_git_repo(initial_commit: false))
  end
end
