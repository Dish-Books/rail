defmodule Rail.Git.Actions.CopyDefaultBranchTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Projects.Schemas.Project

  setup do
    remote = create_temp_git_repo(prefix: "rail_copy_remote")
    clone = create_temp_git_repo(prefix: "rail_copy_clone")
    git!(clone, ["remote", "add", "origin", remote])
    git!(clone, ["fetch", "--quiet", "origin"])
    git!(clone, ["checkout", "--quiet", "--detach"])
    git!(clone, ["branch", "--force", "main", "origin/main"])

    task = Path.join(System.tmp_dir!(), "rail_copy_task_#{System.unique_integer([:positive])}")
    git!(clone, ["clone", "--quiet", "--single-branch", "--branch", "main", clone, task])
    git!(task, ["checkout", "--quiet", "-b", "feature"])
    on_exit(fn -> File.rm_rf(task) end)

    File.write!(Path.join(remote, "later.txt"), "merged later\n")
    git!(remote, ["add", "."])
    git!(remote, ["commit", "-m", "Merged after the task started"])
    git!(clone, ["fetch", "--quiet", "origin"])

    %{
      project: %Project{clone_path: clone, default_branch: "main"},
      clone: clone,
      remote: remote,
      task: task
    }
  end

  test "brings a task's own clone up to the default branch its project's clone last fetched", %{
    project: project,
    remote: remote,
    task: task
  } do
    latest = git!(remote, ["rev-parse", "main"])

    assert :ok = Git.copy_default_branch(project, task)
    assert git!(task, ["rev-parse", "origin/main"]) == latest
    assert git!(task, ["rev-parse", "main"]) == latest
  end

  test "moves origin's copy even while the task has the default branch checked out", %{
    project: project,
    remote: remote,
    task: task
  } do
    git!(task, ["checkout", "--quiet", "main"])
    before = git!(task, ["rev-parse", "main"])

    assert :ok = Git.copy_default_branch(project, task)
    assert git!(task, ["rev-parse", "origin/main"]) == git!(remote, ["rev-parse", "main"])
    assert git!(task, ["rev-parse", "main"]) == before
  end

  test "leaves a worktree and the project's clone itself as they are, since they share the clone's refs", %{
    project: project,
    clone: clone
  } do
    worktree = Path.join(clone, ".worktrees/person")
    git!(clone, ["worktree", "add", "--quiet", "-b", "person", worktree])
    stub(Rail.Tools, :run, fn _command, _args, _opts -> flunk("git was run") end)

    assert :ok = Git.copy_default_branch(project, worktree)
    assert :ok = Git.copy_default_branch(project, clone)
  end

  test "says what git said when the project's clone has not fetched the default branch", %{
    project: project,
    task: task
  } do
    assert {:error, output} = Git.copy_default_branch(%{project | default_branch: "develop"}, task)
    assert output =~ "couldn't find remote ref refs/remotes/origin/develop"
  end
end
