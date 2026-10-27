defmodule Rail.Git.Actions.CommitsSinceTest do
  use Rail.DataCase, async: true

  alias Rail.Git

  setup do
    repo = create_temp_git_repo()
    %{repo: repo, base: repo |> git!(["rev-parse", "HEAD"]) |> String.trim()}
  end

  test "plain commits since an ancestor hold no merge", %{repo: repo, base: base} do
    git!(repo, ["commit", "--allow-empty", "-m", "the fix"])

    assert {:ok, %{merges: false}} = Git.commits_since(repo, base)
  end

  test "a merge since the ancestor is said", %{repo: repo, base: base} do
    git!(repo, ["checkout", "--quiet", "-b", "other"])
    git!(repo, ["commit", "--allow-empty", "-m", "the default branch's work"])
    git!(repo, ["checkout", "--quiet", "main"])
    git!(repo, ["commit", "--allow-empty", "-m", "the branch's work"])
    git!(repo, ["merge", "--quiet", "--no-edit", "other"])

    assert {:ok, %{merges: true}} = Git.commits_since(repo, base)
  end

  test "a commit HEAD does not come from, or one git does not know, is not an ancestor", %{repo: repo, base: base} do
    git!(repo, ["commit", "--quiet", "--amend", "--allow-empty", "-m", "initial commit, reworded"])

    assert {:error, :not_ancestor} = Git.commits_since(repo, base)
    assert {:error, :not_ancestor} = Git.commits_since(repo, String.duplicate("0", 40))
  end
end
