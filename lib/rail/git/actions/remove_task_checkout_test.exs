defmodule Rail.Git.Actions.RemoveTaskCheckoutTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Pipeline.Schemas.Task

  setup do
    create_task_checkout()
  end

  test "deletes a task's repository, its checkout and its branch's folder, and leaves the project's clone as it was",
       %{clone: clone, project: project, task: task, repo: repo, checkout: checkout} do
    git!(clone, ["branch", task.worktree_name])
    refs = git!(clone, ["show-ref"])

    assert :ok = Git.remove_task_checkout(project, task)

    refute File.exists?(checkout)
    refute File.exists?(repo)
    refute File.exists?(Path.dirname(checkout))
    assert git!(clone, ["show-ref"]) == refs
  end

  test "forgets when the task last synced, so a checkout made again is synced at once", %{project: project, task: task} do
    stub(Rail, :checkout_sync_ms, fn -> 60_000 end)
    assert :ok = Git.sync_checkout(task)

    assert :ok = Git.remove_task_checkout(project, task)
    {:ok, checkout} = Git.get_or_create_worktree(project, task)
    File.write!(Path.join(checkout, "new.ex"), "new\n")

    assert Git.list_changed_paths(task) == ["new.ex"]
  end

  test "removes a task's worktree from the project's clone, and its branch there", %{
    clone: clone,
    project: project,
    task: task
  } do
    path = Path.join(clone, ".worktrees/feature-worktree")
    git!(clone, ["worktree", "add", "--quiet", "-b", "feature-worktree", path])

    assert :ok = Git.remove_task_checkout(project, %{task | worktree_path: path, worktree_name: "feature-worktree"})

    refute File.exists?(path)
    refute git!(clone, ["worktree", "list"]) =~ "feature-worktree"
    refute git!(clone, ["branch", "--list"]) =~ "feature-worktree"
  end

  test "prunes a worktree someone already deleted, and deletes its branch", %{
    clone: clone,
    project: project,
    task: task
  } do
    path = Path.join(clone, ".worktrees/feature-gone")
    git!(clone, ["worktree", "add", "--quiet", "-b", "feature-gone", path])
    File.rm_rf!(path)

    assert :ok = Git.remove_task_checkout(project, %{task | worktree_path: path, worktree_name: "feature-gone"})

    refute git!(clone, ["worktree", "list"]) =~ "feature-gone"
    refute git!(clone, ["branch", "--list"]) =~ "feature-gone"
  end

  test "deletes a repository and checkout left half made, and keeps a branch's folder that still holds something", %{
    project: project,
    task: task
  } do
    folder = Path.join(System.tmp_dir!(), "rail_remove_half_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(folder) end)
    half = %{task | worktree_path: Path.join(folder, "repo"), worktree_name: nil}
    File.mkdir_p!(half.worktree_path <> ".new/.git")
    File.mkdir_p!(Task.repo_path(half) <> ".new")
    File.mkdir_p!(Path.join(folder, "other"))

    assert :ok = Git.remove_task_checkout(project, half)

    refute File.exists?(half.worktree_path <> ".new")
    refute File.exists?(Task.repo_path(half) <> ".new")
    assert File.dir?(Path.join(folder, "other"))
  end
end
