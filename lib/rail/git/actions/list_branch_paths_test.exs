defmodule Rail.Git.Actions.ListBranchPathsTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Pipeline.Schemas.Task

  setup do
    %{checkout: checkout} = context = create_task_checkout()
    File.write!(Path.join(checkout, "kept.ex"), "kept\n")
    File.write!(Path.join(checkout, "edited.ex"), "before\n")
    git!(checkout, ["add", "."])
    git!(checkout, ["commit", "-m", "base"])
    git!(checkout, ["push", "--quiet", "origin", "HEAD:main"])
    :ok = Git.fetch_default_branch(context.project, context.task)

    File.write!(Path.join(checkout, "shipped.ex"), "committed\n")
    git!(checkout, ["add", "."])
    git!(checkout, ["commit", "-m", "committed change"])
    File.write!(Path.join(checkout, "edited.ex"), "after\n")
    File.write!(Path.join(checkout, "wip.ex"), "untracked\n")

    context
  end

  test "gives back the paths the branch changed since it forked, committed, edited or untracked", %{task: task} do
    paths = ["shipped.ex", "edited.ex", "wip.ex", "kept.ex", "lib/made_up.ex"]

    assert Git.list_branch_paths(task, paths) == MapSet.new(["shipped.ex", "edited.ex", "wip.ex"])
    assert Git.list_branch_paths(task, ["kept.ex"]) == MapSet.new()
  end

  test "says nil where there is no repository to ask, and asks nothing of no paths", %{task: task} do
    assert Git.list_branch_paths(%{task | worktree_path: nil}, ["shipped.ex"]) == nil
    assert Git.list_branch_paths(task, []) == MapSet.new()

    File.rm_rf!(Task.repo_path(task))
    assert Git.list_branch_paths(task, ["shipped.ex"]) == nil
  end
end
