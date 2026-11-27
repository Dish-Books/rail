defmodule Rail.Git.Actions.PushBranchTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.GitHub.Client
  alias Rail.Tools.Schemas.OsProcess

  # As Rail lays them out: origin, the project's clone of it, the task's repository and its checkout, on a branch
  # of its own.
  setup do
    %{checkout: checkout} = context = create_task_checkout(task: [worktree_name: "feature"])
    File.write!(Path.join(checkout, "feature.ex"), "one\n")
    git!(checkout, ["add", "."])
    git!(checkout, ["commit", "--quiet", "-m", "feature"])

    Map.merge(context, %{scope: system_scope(), sha: String.trim(git!(checkout, ["rev-parse", "HEAD"]))})
  end

  test "mints its own token and pushes the commit as the task's branch, which the checkout then tracks", %{
    scope: scope,
    task: task,
    repo: repo,
    checkout: checkout,
    remote: remote,
    sha: sha
  } do
    Req.Test.expect(Client, fn conn ->
      assert conn.request_path == "/app/installations/1/access_tokens"
      Req.Test.json(conn, %{"token" => "ghs_installation_token"})
    end)

    assert :ok = Git.push_branch(scope, task, sha)
    assert git!(remote, ["rev-parse", "feature"]) == sha <> "\n"
    assert git!(checkout, ["rev-parse", "origin/feature"]) == sha <> "\n"
    assert git!(checkout, ["rev-parse", "--abbrev-ref", "feature@{upstream}"]) == "origin/feature\n"
    assert git!(repo, ["rev-parse", "refs/remotes/origin/feature"]) == sha <> "\n"
    refute Git.branch_unpushed?(task)
  end

  test "pushes the commit it is given, not one committed since", %{
    scope: scope,
    task: task,
    checkout: checkout,
    remote: remote,
    sha: sha
  } do
    git!(checkout, ["commit", "--quiet", "--allow-empty", "-m", "after CI started"])

    assert :ok = Git.push_branch(scope, task, sha)
    assert git!(remote, ["rev-parse", "feature"]) == sha <> "\n"
  end

  # The checkout's .git is the sandbox's to write. Each of these would run in Rail's container, or send the push
  # somewhere else, if Rail pushed from there or ran its hooks; the clone's hook is the project's, which Rail runs
  # none of either.
  test "runs no hook and reads none of the checkout's config", %{
    scope: scope,
    task: task,
    clone: clone,
    checkout: checkout,
    remote: remote,
    sha: sha
  } do
    ran = Path.join(System.tmp_dir!(), "rail_push_ran_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(ran) end)
    File.mkdir_p!(ran)

    for {dir, name} <- [{checkout, "checkout"}, {clone, "clone"}],
        hook <- ["pre-push", "reference-transaction", "post-checkout"] do
      path = Path.join([dir, ".git", "hooks", hook])
      File.write!(path, "#!/bin/sh\ntouch #{ran}/#{name}-#{hook}\nexit 1\n")
      File.chmod!(path, 0o755)
    end

    git!(checkout, ["config", "core.fsmonitor", "touch #{ran}/fsmonitor; false"])
    git!(checkout, ["config", "credential.helper", "!touch #{ran}/credential-helper; false"])
    git!(checkout, ["config", "remote.origin.url", "/tmp/nowhere_#{System.unique_integer([:positive])}"])

    assert :ok = Git.push_branch(scope, task, sha)
    assert git!(remote, ["rev-parse", "feature"]) == sha <> "\n"
    assert File.ls!(ran) == []

    # A plain git in the same checkout does run them.
    System.cmd("git", ["update-ref", "refs/heads/probe", sha], cd: checkout, stderr_to_stdout: true, env: [])
    assert "checkout-reference-transaction" in File.ls!(ran)
  end

  test "takes the checkout's receipt for the tree a passed CI run ran on, with the branch", %{
    scope: scope,
    task: task,
    checkout: checkout,
    remote: remote,
    sha: sha
  } do
    tree = String.trim(git!(checkout, ["rev-parse", "#{sha}^{tree}"]))
    receipt = git!(checkout, ["commit-tree", tree, "-m", "ci receipt for tree #{tree}"])
    git!(checkout, ["update-ref", "refs/ci-receipts/#{tree}", String.trim(receipt)])

    assert :ok = Git.push_branch(scope, task, %OsProcess{kind: :ci, exit_code: 0, head_sha: sha})
    assert git!(remote, ["rev-parse", "feature"]) == sha <> "\n"
    assert git!(remote, ["rev-parse", "refs/ci-receipts/#{tree}"]) == receipt
  end

  test "pushes a passed CI run's commit alone when the checkout has no receipt for it", %{
    scope: scope,
    task: task,
    remote: remote,
    sha: sha
  } do
    assert :ok = Git.push_branch(scope, task, %OsProcess{kind: :ci, exit_code: 0, head_sha: sha})
    assert git!(remote, ["rev-parse", "feature"]) == sha <> "\n"
    assert git!(remote, ["for-each-ref", "refs/ci-receipts"]) == ""
  end

  # git ls-remote matches the end of a ref's name, so a ref that only ends like the receipt's is not taken for it.
  test "takes only the ref named exactly for the receipt", %{
    scope: scope,
    task: task,
    repo: repo,
    checkout: checkout,
    remote: remote,
    sha: sha
  } do
    tree = String.trim(git!(checkout, ["rev-parse", "#{sha}^{tree}"]))
    assert :ok = Git.sync_checkout(task)
    git!(repo, ["update-ref", "refs/planted/refs/ci-receipts/#{tree}", sha])

    assert :ok = Git.push_branch(scope, task, %OsProcess{kind: :ci, exit_code: 0, head_sha: sha})
    assert git!(remote, ["for-each-ref", "--format=%(refname)"]) =~ "refs/heads/feature"
    refute git!(remote, ["for-each-ref", "--format=%(refname)"]) =~ "ci-receipts"
  end

  # A receipt says the tree passed every gate. Rail only says so of a tree it watched CI pass on: with no CI run, or
  # one on another commit, the checkout's receipts stay where they are, whoever wrote them.
  test "never pushes a receipt for a tree it did not see CI pass on", %{
    scope: scope,
    task: task,
    checkout: checkout,
    remote: remote,
    sha: sha
  } do
    tree = String.trim(git!(checkout, ["rev-parse", "#{sha}^{tree}"]))
    git!(checkout, ["update-ref", "refs/ci-receipts/#{tree}", sha])

    File.write!(Path.join(checkout, "feature.ex"), "two\n")
    git!(checkout, ["commit", "--quiet", "-am", "after CI"])
    later = String.trim(git!(checkout, ["rev-parse", "HEAD"]))
    later_tree = String.trim(git!(checkout, ["rev-parse", "#{later}^{tree}"]))
    git!(checkout, ["update-ref", "refs/ci-receipts/#{later_tree}", later])

    # Pushed with no CI run at all.
    assert :ok = Git.push_branch(scope, task, sha)
    assert git!(remote, ["for-each-ref", "refs/ci-receipts"]) == ""

    # CI passed on the first commit only, so the later tree's receipt stays behind even as the branch moves on.
    assert :ok = Git.push_branch(scope, task, %OsProcess{kind: :ci, exit_code: 0, head_sha: sha})
    assert git!(remote, ["for-each-ref", "--format=%(refname)", "refs/ci-receipts"]) == "refs/ci-receipts/#{tree}\n"

    assert :ok = Git.push_branch(scope, task, later)
    assert git!(remote, ["rev-parse", "feature"]) == later <> "\n"
    assert git!(remote, ["for-each-ref", "--format=%(refname)", "refs/ci-receipts"]) == "refs/ci-receipts/#{tree}\n"
  end

  test "pushes nothing for a CI run that failed, or one with no commit recorded, or anything but a commit SHA", %{
    scope: scope,
    task: task,
    remote: remote,
    sha: sha
  } do
    assert {:error, "This CI run did not pass on a commit Rail recorded, so nothing was pushed."} =
             Git.push_branch(scope, task, %OsProcess{kind: :ci, exit_code: 1, head_sha: sha})

    assert {:error, "This CI run did not pass on a commit Rail recorded, so nothing was pushed."} =
             Git.push_branch(scope, task, %OsProcess{kind: :ci, exit_code: 0, head_sha: nil})

    assert {:error, "git could not say which commit the branch is on."} = Git.push_branch(scope, task, nil)

    assert {:error, ~s("--upload-pack=touch x" is not a commit SHA.)} =
             Git.push_branch(scope, task, "--upload-pack=touch x")

    assert git!(remote, ["branch", "--list", "feature"]) == ""
  end

  test "reports what git said when the commit cannot be taken or pushed", %{
    scope: scope,
    task: task,
    clone: clone,
    sha: sha
  } do
    assert {:error, output} = Git.push_branch(scope, task, String.duplicate("0", 40))
    assert output =~ "not our ref" or output =~ "upload-pack"

    git!(clone, ["remote", "set-url", "origin", "/tmp/nowhere_#{System.unique_integer([:positive])}"])
    assert {:error, output} = Git.push_branch(scope, task, sha)
    assert output =~ "does not appear to be a git repository"
  end

  test "says so when GitHub will not mint a token", %{scope: scope, task: task, sha: sha} do
    Req.Test.expect(Client, fn conn ->
      conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Not Found"})
    end)

    assert {:error, {:github_api_error, 404, _body}} = Git.push_branch(scope, task, sha)
  end

  test "refuses a branch rewritten since it was last pushed", %{
    scope: scope,
    task: task,
    checkout: checkout,
    remote: remote,
    sha: sha
  } do
    assert :ok = Git.push_branch(scope, task, sha)

    git!(checkout, ["commit", "--quiet", "--amend", "-m", "feature, rewritten"])
    rewritten = String.trim(git!(checkout, ["rev-parse", "HEAD"]))

    assert {:error, output} = Git.push_branch(scope, task, rewritten)
    assert output =~ "[rejected]"
    assert git!(remote, ["rev-parse", "feature"]) == sha <> "\n"
  end

  # A remote that moved on outside Rail holds work Rail never saw.
  test "refuses a remote that holds someone else's push", %{
    scope: scope,
    task: task,
    remote: remote,
    sha: sha
  } do
    theirs = git!(remote, ["commit-tree", "main^{tree}", "-p", "main", "-m", "theirs"])
    git!(remote, ["update-ref", "refs/heads/feature", String.trim(theirs)])

    assert {:error, output} = Git.push_branch(scope, task, sha)
    assert output =~ "[rejected]"
  end

  test "under the docker runtime records origin's branch in the task's repository alone", %{
    scope: scope,
    task: task,
    repo: repo,
    checkout: checkout,
    remote: remote,
    sha: sha
  } do
    assert :ok = Git.sync_checkout(task)
    stub(Rail, :sandbox_runtime, fn -> :docker end)

    assert :ok = Git.push_branch(scope, task, sha)
    assert git!(remote, ["rev-parse", "feature"]) == sha <> "\n"
    assert git!(repo, ["rev-parse", "refs/remotes/origin/feature"]) == sha <> "\n"
    assert {_none, 128} = Rail.Tools.run("git", ["rev-parse", "--verify", "origin/feature"], cd: checkout)
  end
end
