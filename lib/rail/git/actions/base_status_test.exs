defmodule Rail.Git.Actions.BaseStatusTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Pipeline.Schemas.Task

  setup do
    %{remote: remote} = context = create_task_checkout()
    File.write!(Path.join(remote, "shared.ex"), "one\n")
    git!(remote, ["add", "."])
    git!(remote, ["commit", "-m", "the base"])
    :ok = Git.fetch_default_branch(context.project, context.task)
    git!(context.checkout, ["merge", "--quiet", "origin/main"])
    context
  end

  test "a branch with the default branch in its history is not behind, ahead of it or not", %{
    task: task,
    checkout: checkout
  } do
    assert %{behind: false, conflicts: []} = Git.base_status(task, "main")

    git!(checkout, ["commit", "--allow-empty", "-m", "the work"])
    assert %{behind: false, conflicts: []} = Git.base_status(task, "main")
  end

  test "a branch behind it that merges cleanly is behind with nothing in conflict", %{
    task: task,
    project: project,
    remote: remote
  } do
    File.write!(Path.join(remote, "other.ex"), "landed\n")
    git!(remote, ["add", "."])
    git!(remote, ["commit", "-qm", "landed on main"])
    :ok = Git.fetch_default_branch(project, task)

    assert %{behind: true, conflicts: []} = Git.base_status(task, "main")
  end

  test "a branch behind it that changed the same lines conflicts in that file", %{
    task: task,
    project: project,
    remote: remote,
    checkout: checkout
  } do
    File.write!(Path.join(remote, "shared.ex"), "theirs\n")
    git!(remote, ["commit", "-qam", "landed on main"])
    :ok = Git.fetch_default_branch(project, task)
    File.write!(Path.join(checkout, "shared.ex"), "ours\n")
    git!(checkout, ["commit", "-qam", "the work"])

    assert %{behind: true, conflicts: ["shared.ex"]} = Git.base_status(task, "main")
    # Worked out in the task's repository, so the checkout is as the agent left it.
    assert File.read!(Path.join(checkout, "shared.ex")) == "ours\n"
  end

  test "a default branch git cannot read, or a task with no repository, counts as up to date", %{task: task} do
    assert %{behind: false, conflicts: []} = Git.base_status(task, "trunk")

    File.rm_rf!(Task.repo_path(task))
    assert %{behind: false, conflicts: []} = Git.base_status(task, "main")
  end
end
