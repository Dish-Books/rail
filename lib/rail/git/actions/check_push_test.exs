defmodule Rail.Git.Actions.CheckPushTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.GitHub.Client
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Projects

  # The project's clone fetches from origin, and the checkout from the clone, as Rail lays them out.
  setup do
    unique = System.unique_integer([:positive])
    remote = create_temp_git_repo(prefix: "rail_git_remote", initial_commit: false)
    git!(remote, ["config", "receive.denyCurrentBranch", "ignore"])
    clone = Path.join(System.tmp_dir!(), "rail_check_push_clone_#{unique}")
    on_exit(fn -> File.rm_rf(clone) end)
    git!(System.tmp_dir!(), ["clone", "--quiet", remote, clone])
    repo = create_temp_git_repo()
    git!(repo, ["remote", "add", "origin", remote])
    git!(repo, ["commit", "--allow-empty", "-m", "the work"])

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Check Push #{unique}",
        github_repo: "example/check-push-#{unique}",
        github_installation_id: 1,
        default_branch: "main",
        key: "CHK#{unique}",
        clone_path: clone
      })

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{title: "Issue", description: "Check Push"})
    {:ok, task} = Pipeline.create_task(issue, :engineer)

    {:ok, task} = Pipeline.update_task(task, %{worktree_path: repo, worktree_name: "main"})
    on_exit(fn -> File.rm_rf(task.scratch_path) end)
    Req.Test.stub(Client, &Req.Test.json(&1, %{"token" => "ghs_installation_token"}))

    %{task: task, clone: clone, repo: repo, remote: remote}
  end

  test "a branch the remote does not have yet can be pushed", %{task: task} do
    assert :ok = Git.check_push(task)
  end

  test "a branch that adds to what it pushed can be pushed", %{task: task, repo: repo} do
    git!(repo, ["push", "origin", "main"])
    git!(repo, ["merge", "--no-edit", "origin/main"])
    git!(repo, ["commit", "--allow-empty", "-m", "more work"])

    assert :ok = Git.check_push(task)
  end

  # A rebase, an amend or a reset of a pushed commit all leave the remote's tip out of HEAD, a tip it once had.
  test "a branch that rewrote a commit it pushed is refused as rewritten", %{task: task, repo: repo} do
    git!(repo, ["push", "origin", "main"])
    git!(repo, ["commit", "--amend", "--allow-empty", "-m", "the work, reworded"])

    assert {:error, :history_rewritten} = Git.check_push(task)
  end

  # The checkout's config is the sandbox's to write, and the token goes wherever its origin says, so the token's
  # fetch is the clone's and the checkout's origin is never asked.
  test "reads origin through the project's clone, whatever the checkout names as origin", %{task: task, repo: repo} do
    git!(repo, ["push", "origin", "main"])
    git!(repo, ["update-ref", "-d", "refs/remotes/origin/main"])
    git!(repo, ["remote", "set-url", "origin", "/tmp/nowhere_#{System.unique_integer([:positive])}"])
    git!(repo, ["commit", "--amend", "--allow-empty", "-m", "the work, reworded"])

    assert {:error, :history_rewritten} = Git.check_push(task)
  end

  test "a remote someone else pushed to outside Rail is said so", %{task: task, repo: repo, remote: remote} do
    git!(repo, ["push", "origin", "main"])
    elsewhere = Path.join(System.tmp_dir!(), "rail_git_elsewhere_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(elsewhere) end)
    git!(System.tmp_dir!(), ["clone", "--quiet", remote, elsewhere])
    git!(elsewhere, ["config", "user.email", "else@rail.local"])
    git!(elsewhere, ["config", "user.name", "Someone Else"])
    git!(elsewhere, ["commit", "--allow-empty", "-m", "theirs"])
    git!(elsewhere, ["push", "--quiet", "origin", "main"])
    git!(repo, ["commit", "--allow-empty", "-m", "more work"])

    assert {:error, :pushed_outside_rail} = Git.check_push(task)

    # Merging what they pushed in is the way on.
    git!(repo, ["merge", "--no-edit", "origin/main"])
    assert :ok = Git.check_push(task)
  end

  test "a remote that cannot be read leaves the push to say what is wrong", %{task: task, clone: clone} do
    git!(clone, ["remote", "set-url", "origin", "/tmp/nowhere_#{System.unique_integer([:positive])}"])
    assert :ok = Git.check_push(task)

    Req.Test.stub(Client, &(&1 |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Not Found"})))
    assert :ok = Git.check_push(task)
  end
end
