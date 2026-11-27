defmodule Rail.Git.Actions.CheckPushTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.GitHub.Client

  # The project's clone fetches from origin, and the task's repository and checkout from the clone, as Rail lays them out.
  setup do
    %{checkout: checkout} = context = create_task_checkout()
    git!(checkout, ["commit", "--allow-empty", "-m", "the work"])
    push = fn -> Git.push_branch(system_scope(), context.task, String.trim(git!(checkout, ["rev-parse", "HEAD"]))) end
    Map.put(context, :push, push)
  end

  test "a branch the remote does not have yet can be pushed", %{task: task} do
    assert :ok = Git.check_push(task)
  end

  test "a branch that adds to what it pushed can be pushed", %{task: task, checkout: checkout, push: push} do
    assert :ok = push.()
    git!(checkout, ["commit", "--allow-empty", "-m", "more work"])

    assert :ok = Git.check_push(task)
  end

  # A rebase, an amend or a reset of a pushed commit all leave the remote's tip out of the branch, a tip it once had.
  test "a branch that rewrote a commit it pushed is refused as rewritten", %{
    task: task,
    checkout: checkout,
    push: push
  } do
    assert :ok = push.()
    git!(checkout, ["commit", "--amend", "--allow-empty", "-m", "the work, reworded"])

    assert {:error, :history_rewritten} = Git.check_push(task)
  end

  # The token's fetch is the clone's, and the checkout's origin is never asked.
  test "reads origin through the project's clone, whatever the checkout names as origin", %{
    task: task,
    repo: repo,
    checkout: checkout,
    push: push
  } do
    assert :ok = push.()
    git!(repo, ["update-ref", "-d", "refs/remotes/origin/#{task.worktree_name}"])
    git!(checkout, ["remote", "set-url", "origin", "/tmp/nowhere_#{System.unique_integer([:positive])}"])
    git!(checkout, ["commit", "--amend", "--allow-empty", "-m", "the work, reworded"])

    assert {:error, :history_rewritten} = Git.check_push(task)
  end

  test "a remote someone else pushed to outside Rail is said so, and merging it in is the way on", %{
    task: %{worktree_name: branch} = task,
    checkout: checkout,
    remote: remote,
    push: push
  } do
    assert :ok = push.()
    elsewhere = Path.join(System.tmp_dir!(), "rail_git_elsewhere_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(elsewhere) end)
    git!(System.tmp_dir!(), ["clone", "--quiet", "--branch", branch, remote, elsewhere])
    git!(elsewhere, ["config", "user.email", "else@rail.local"])
    git!(elsewhere, ["config", "user.name", "Someone Else"])
    git!(elsewhere, ["commit", "--allow-empty", "-m", "theirs"])
    git!(elsewhere, ["push", "--quiet", "origin", branch])
    git!(checkout, ["commit", "--allow-empty", "-m", "more work"])

    assert {:error, :pushed_outside_rail} = Git.check_push(task)

    git!(checkout, ["merge", "--no-edit", "origin/#{branch}"])
    assert :ok = Git.check_push(task)
  end

  test "a remote that cannot be read leaves the push to say what is wrong", %{task: task, clone: clone} do
    git!(clone, ["remote", "set-url", "origin", "/tmp/nowhere_#{System.unique_integer([:positive])}"])
    assert :ok = Git.check_push(task)

    Req.Test.stub(Client, &(&1 |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Not Found"})))
    assert :ok = Git.check_push(task)
  end

  test "under the docker runtime the remote branch goes only into the task's repository", %{
    task: task,
    repo: repo,
    checkout: checkout,
    push: push
  } do
    assert :ok = push.()
    stub(Rail, :sandbox_runtime, fn -> :docker end)
    git!(checkout, ["update-ref", "-d", "refs/remotes/origin/#{task.worktree_name}"])
    git!(repo, ["update-ref", "-d", "refs/remotes/origin/#{task.worktree_name}"])

    assert :ok = Git.check_push(task)
    assert git!(repo, ["rev-parse", "refs/remotes/origin/#{task.worktree_name}"]) == git!(checkout, ["rev-parse", "HEAD"])
    assert {_none, 128} = Rail.Tools.run("git", ["rev-parse", "--verify", "origin/#{task.worktree_name}"], cd: checkout)
  end
end
