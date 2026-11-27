defmodule Rail.Git.Actions.ListChangedPathsTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Pipeline.Schemas.Task

  setup do
    create_task_checkout()
  end

  test "every path changed, deleted or untracked since the branch's head, sorted", %{task: task, checkout: checkout} do
    File.write!(Path.join(checkout, "gone.txt"), "soon gone\n")
    git!(checkout, ["add", "."])
    git!(checkout, ["commit", "-m", "add gone"])

    File.write!(Path.join(checkout, "tracked.txt"), "edited\n")
    File.rm!(Path.join(checkout, "gone.txt"))
    File.mkdir_p!(Path.join(checkout, "lib"))
    File.write!(Path.join([checkout, "lib", "new file.ex"]), "new\n")
    File.write!(Path.join(checkout, "staged.ex"), "staged\n")
    git!(checkout, ["add", "staged.ex"])

    assert Git.list_changed_paths(task) == ["gone.txt", "lib/new file.ex", "staged.ex", "tracked.txt"]
  end

  test "a clean checkout, or a task with no repository, has nothing changed", %{task: task} do
    assert Git.list_changed_paths(task) == []

    File.rm_rf!(Task.repo_path(task))
    assert Git.list_changed_paths(task) == []
  end
end
