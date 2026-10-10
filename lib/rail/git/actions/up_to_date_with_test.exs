defmodule Rail.Git.Actions.UpToDateWithTest do
  use ExUnit.Case, async: true

  import RailTest.Helpers

  alias Rail.Git

  setup do
    repo = create_temp_git_repo()
    git!(repo, ["commit", "--allow-empty", "-m", "landed on main"])
    git!(repo, ["update-ref", "refs/remotes/origin/main", "HEAD"])
    %{repo: repo}
  end

  test "a branch with the default branch in its history is up to date, ahead of it or not", %{repo: repo} do
    assert Git.up_to_date_with?(repo, "main")

    git!(repo, ["commit", "--allow-empty", "-m", "the work"])
    assert Git.up_to_date_with?(repo, "main")
  end

  test "a branch missing a commit the default branch has is behind", %{repo: repo} do
    git!(repo, ["reset", "--quiet", "--hard", "HEAD~1"])

    refute Git.up_to_date_with?(repo, "main")
  end

  # Nothing can be said about a default branch git cannot find, so the turn is not told it is behind.
  test "a default branch git cannot read counts as up to date", %{repo: repo} do
    assert Git.up_to_date_with?(repo, "trunk")
  end
end
