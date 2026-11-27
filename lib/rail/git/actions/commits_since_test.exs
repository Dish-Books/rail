defmodule Rail.Git.Actions.CommitsSinceTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Pipeline.Schemas.Task

  setup do
    %{checkout: checkout} = context = create_task_checkout()
    Map.put(context, :base, checkout |> git!(["rev-parse", "HEAD"]) |> String.trim())
  end

  test "plain commits since an ancestor hold no merge", %{task: task, checkout: checkout, base: base} do
    git!(checkout, ["commit", "--allow-empty", "-m", "the fix"])

    assert {:ok, %{merges: false}} = Git.commits_since(task, base)
  end

  test "a merge since the ancestor is said", %{
    task: %{worktree_name: branch} = task,
    checkout: checkout,
    base: base
  } do
    git!(checkout, ["checkout", "--quiet", "-b", "other"])
    git!(checkout, ["commit", "--allow-empty", "-m", "the default branch's work"])
    git!(checkout, ["checkout", "--quiet", branch])
    git!(checkout, ["commit", "--allow-empty", "-m", "the branch's work"])
    git!(checkout, ["merge", "--quiet", "--no-edit", "other"])

    assert {:ok, %{merges: true}} = Git.commits_since(task, base)
  end

  test "a commit the branch does not come from, or one git does not know, is not an ancestor", %{
    task: task,
    checkout: checkout,
    base: base
  } do
    git!(checkout, ["commit", "--quiet", "--amend", "--allow-empty", "-m", "initial commit, reworded"])

    assert {:error, :not_ancestor} = Git.commits_since(task, base)
    assert {:error, :not_ancestor} = Git.commits_since(task, String.duplicate("0", 40))

    File.rm_rf!(Task.repo_path(task))
    assert {:error, :not_ancestor} = Git.commits_since(task, base)
  end
end
