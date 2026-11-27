defmodule Rail.Git.Actions.WorktreeDirtyTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Pipeline.Schemas.Task

  setup do
    create_task_checkout()
  end

  test "a freshly made checkout is clean", %{task: task} do
    refute Git.worktree_dirty?(task)
  end

  test "a modified tracked file makes it dirty", %{task: task, checkout: checkout} do
    File.write!(Path.join(checkout, "tracked.txt"), "two\n")

    assert Git.worktree_dirty?(task)
  end

  test "an untracked file makes it dirty, and committing it clean again", %{task: task, checkout: checkout} do
    File.write!(Path.join(checkout, "untracked.txt"), "wip\n")
    assert Git.worktree_dirty?(task)

    git!(checkout, ["add", "."])
    git!(checkout, ["commit", "-m", "wip"])
    refute Git.worktree_dirty?(task)
  end

  test "a file under .rail does, like any other", %{task: task, checkout: checkout} do
    File.mkdir_p!(Path.join(checkout, ".rail"))
    File.write!(Path.join(checkout, ".rail/settings.json"), "{}\n")

    assert Git.worktree_dirty?(task)
  end

  test "a task with no repository is not dirty", %{task: task} do
    File.rm_rf!(Task.repo_path(task))

    refute Git.worktree_dirty?(task)
  end
end
