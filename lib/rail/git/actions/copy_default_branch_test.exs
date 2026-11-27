defmodule Rail.Git.Actions.CopyDefaultBranchTest do
  use Rail.DataCase, async: true

  alias Rail.Git

  setup do
    %{remote: remote, clone: clone} = context = create_task_checkout()
    File.write!(Path.join(remote, "later.txt"), "merged later\n")
    git!(remote, ["add", "."])
    git!(remote, ["commit", "-m", "Merged after the task started"])
    git!(clone, ["fetch", "--quiet", "origin"])
    context
  end

  test "brings a task's repository and checkout up to the default branch its project's clone last fetched", %{
    project: project,
    remote: remote,
    task: task,
    repo: repo,
    checkout: checkout
  } do
    latest = git!(remote, ["rev-parse", "main"])

    assert :ok = Git.copy_default_branch(project, task)
    assert git!(repo, ["rev-parse", "refs/remotes/origin/main"]) == latest
    assert git!(checkout, ["rev-parse", "origin/main"]) == latest
    assert git!(checkout, ["rev-parse", "main"]) == latest
    # The repository holds no branch but the task's, so the default is only origin's there.
    assert {_none, 128} = Rail.Tools.run("git", ["rev-parse", "--verify", "refs/heads/main"], cd: repo)
  end

  test "under the docker runtime the checkout is the sandbox's, so only the repository is brought up", %{
    project: project,
    remote: remote,
    task: task,
    repo: repo,
    checkout: checkout
  } do
    stub(Rail, :sandbox_runtime, fn -> :docker end)
    before = git!(checkout, ["rev-parse", "origin/main"])

    assert :ok = Git.copy_default_branch(project, task)
    assert git!(repo, ["rev-parse", "refs/remotes/origin/main"]) == git!(remote, ["rev-parse", "main"])
    assert git!(checkout, ["rev-parse", "origin/main"]) == before
  end

  test "moves origin's copy even while a checkout has the default branch checked out", %{
    project: project,
    remote: remote,
    checkout: checkout
  } do
    git!(checkout, ["checkout", "--quiet", "-b", "main", "origin/main"])
    before = git!(checkout, ["rev-parse", "main"])

    assert :ok = Git.copy_default_branch(project, checkout)
    assert git!(checkout, ["rev-parse", "origin/main"]) == git!(remote, ["rev-parse", "main"])
    assert git!(checkout, ["rev-parse", "main"]) == before
  end

  test "leaves the project's clone itself as it is", %{project: project, clone: clone} do
    stub(Rail.Tools, :run, fn _command, _args, _opts -> flunk("git was run") end)

    assert :ok = Git.copy_default_branch(project, clone)
  end

  test "says what git said when the project's clone has not fetched the default branch", %{
    project: project,
    task: task,
    checkout: checkout
  } do
    assert {:error, output} = Git.copy_default_branch(%{project | default_branch: "develop"}, task)
    assert output =~ "couldn't find remote ref refs/remotes/origin/develop"

    # A ref git cannot lock in the checkout fails the copy there, after the repository's.
    File.mkdir_p!(Path.join(checkout, ".git/refs/remotes/origin"))
    File.write!(Path.join(checkout, ".git/refs/remotes/origin/main.lock"), "")
    assert {:error, output} = Git.copy_default_branch(project, task)
    assert output =~ "main.lock"
  end
end
