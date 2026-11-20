defmodule Rail.Git.Actions.RemoveTaskCheckoutTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.GitHub.Client
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project

  setup do
    Req.Test.stub(Client, &Req.Test.json(&1, %{"token" => "ghs_token"}))
    remote = create_temp_git_repo(prefix: "rail_remove_remote")
    repo = create_temp_git_repo()
    git!(repo, ["remote", "add", "origin", remote])
    tasks = Path.join([Rail.tasks_root(), "prj_remove_#{System.unique_integer([:positive])}"])
    on_exit(fn -> File.rm_rf(tasks) end)

    %{repo: repo, tasks: tasks, project: %Project{clone_path: repo, default_branch: "main", github_installation_id: 1}}
  end

  test "deletes a task's own clone and its branch's folder, and leaves the project's clone as it was", %{
    repo: repo,
    tasks: tasks,
    project: project
  } do
    task = %Task{worktree_path: Path.join([tasks, "feature-clone", "repo"]), worktree_name: "feature-clone"}
    assert {:ok, path} = Git.get_or_create_worktree(project, task)
    git!(repo, ["branch", "feature-clone"])
    refs = git!(repo, ["show-ref"])

    assert :ok = Git.remove_task_checkout(project, task)

    refute File.exists?(path)
    refute File.exists?(Path.dirname(path))
    assert git!(repo, ["show-ref"]) == refs
  end

  test "removes a task's worktree from the project's clone, and its branch there", %{repo: repo, project: project} do
    path = Path.join(repo, ".worktrees/feature-worktree")
    git!(repo, ["worktree", "add", "--quiet", "-b", "feature-worktree", path])

    assert :ok = Git.remove_task_checkout(project, %Task{worktree_path: path, worktree_name: "feature-worktree"})

    refute File.exists?(path)
    refute git!(repo, ["worktree", "list"]) =~ "feature-worktree"
    refute git!(repo, ["branch", "--list"]) =~ "feature-worktree"
  end

  test "prunes a worktree someone already deleted, and deletes its branch", %{repo: repo, project: project} do
    path = Path.join(repo, ".worktrees/feature-gone")
    git!(repo, ["worktree", "add", "--quiet", "-b", "feature-gone", path])
    File.rm_rf!(path)

    assert :ok = Git.remove_task_checkout(project, %Task{worktree_path: path, worktree_name: "feature-gone"})

    refute git!(repo, ["worktree", "list"]) =~ "feature-gone"
    refute git!(repo, ["branch", "--list"]) =~ "feature-gone"
  end

  test "deletes a clone left half made, and keeps a branch's folder that still holds something", %{
    tasks: tasks,
    project: project
  } do
    path = Path.join([tasks, "feature-half", "repo"])
    File.mkdir_p!(path <> ".new/.git")
    File.mkdir_p!(Path.join([tasks, "feature-half", "other"]))

    assert :ok = Git.remove_task_checkout(project, %Task{worktree_path: path, worktree_name: nil})

    refute File.exists?(path <> ".new")
    assert File.dir?(Path.join([tasks, "feature-half", "other"]))
  end
end
