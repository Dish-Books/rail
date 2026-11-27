defmodule Rail.Git.Actions.BranchChangedTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task

  setup do
    create_task_checkout()
  end

  test "a branch that has done nothing has not changed", %{task: task} do
    refute Git.branch_changed?(task)
  end

  test "a commit on the branch is a change", %{task: task, checkout: checkout} do
    File.write!(Path.join(checkout, "shipped.ex"), "committed\n")
    git!(checkout, ["add", "."])
    git!(checkout, ["commit", "-m", "committed change"])

    assert Git.branch_changed?(task)
  end

  test "an edit nobody has committed is a change", %{task: task, checkout: checkout} do
    File.write!(Path.join(checkout, "tracked.txt"), "edited\n")

    assert Git.branch_changed?(task)
  end

  test "a file git has never seen is a change", %{task: task, checkout: checkout} do
    File.write!(Path.join(checkout, "brand_new.ex"), "new\n")

    assert Git.branch_changed?(task)
  end

  test "a new file under .rail is a change, like any other", %{task: task, checkout: checkout} do
    File.mkdir_p!(Path.join(checkout, ".rail"))
    File.write!(Path.join(checkout, ".rail/notes.md"), "notes\n")

    assert Git.branch_changed?(task)
  end

  test "a task whose repository is gone has not changed", %{task: task} do
    File.rm_rf!(Task.repo_path(task))
    refute Git.branch_changed?(task)

    {:ok, task} = Pipeline.update_task(task, %{worktree_path: "/tmp/gone_#{System.unique_integer([:positive])}"})
    refute Git.branch_changed?(task)
  end
end
