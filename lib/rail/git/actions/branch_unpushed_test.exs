defmodule Rail.Git.Actions.BranchUnpushedTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Pipeline.Schemas.Task

  setup do
    create_task_checkout()
  end

  test "a fresh branch from the default branch has nothing to push, with no upstream", %{task: task} do
    refute Git.branch_unpushed?(task)
  end

  test "a commit only in the checkout is unpushed until Rail pushes it", %{task: task, checkout: checkout} do
    git!(checkout, ["commit", "--allow-empty", "-m", "the work"])
    assert Git.branch_unpushed?(task)

    assert :ok = Git.push_branch(system_scope(), task, String.trim(git!(checkout, ["rev-parse", "HEAD"])))
    refute Git.branch_unpushed?(task)
  end

  test "a branch rewritten since its push is unpushed", %{task: task, checkout: checkout} do
    git!(checkout, ["commit", "--allow-empty", "-m", "the work"])
    assert :ok = Git.push_branch(system_scope(), task, String.trim(git!(checkout, ["rev-parse", "HEAD"])))
    git!(checkout, ["commit", "--amend", "--allow-empty", "-m", "the work, reworded"])

    assert Git.branch_unpushed?(task)
  end

  test "a task whose repository git cannot read counts as unpushed", %{task: task} do
    File.rm_rf!(Task.repo_path(task))

    assert Git.branch_unpushed?(task)
  end
end
