defmodule Rail.Git.Actions.PushBranchTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.GitHub.Client
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Projects
  alias Rail.Tools.Schemas.OsProcess

  # As Rail lays them out: origin, the project's clone of it, and the task's checkout, a clone of the clone that
  # pushes to origin, on a branch of its own.
  setup do
    scope = system_scope()
    unique = System.unique_integer([:positive])
    remote = create_temp_git_repo(prefix: "rail_git_remote")
    git!(remote, ["config", "receive.denyCurrentBranch", "ignore"])

    clone = Path.join(System.tmp_dir!(), "rail_push_clone_#{unique}")
    repo = Path.join(System.tmp_dir!(), "rail_push_checkout_#{unique}")
    on_exit(fn -> Enum.each([clone, repo], &File.rm_rf/1) end)
    git!(System.tmp_dir!(), ["clone", "--quiet", remote, clone])
    git!(System.tmp_dir!(), ["clone", "--quiet", clone, repo])
    git!(repo, ["remote", "set-url", "origin", remote])
    git!(repo, ["config", "user.email", "test@rail.local"])
    git!(repo, ["config", "user.name", "Rail Test"])
    git!(repo, ["config", "commit.gpgsign", "false"])
    git!(repo, ["checkout", "--quiet", "-b", "feature"])

    {:ok, project} =
      Projects.create_project(scope, %{
        name: "Push #{unique}",
        github_repo: "example/push-#{unique}",
        github_installation_id: 1,
        default_branch: "main",
        key: "PSH#{unique}",
        clone_path: clone
      })

    {:ok, issue} = Issues.create_issue(scope, project, %{title: "Issue", description: "Push Branch"})
    {:ok, task} = Pipeline.create_task(issue, :engineer)
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: repo, worktree_name: "feature"})
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    Req.Test.stub(Client, &Req.Test.json(&1, %{"token" => "ghs_installation_token"}))

    File.write!(Path.join(repo, "feature.ex"), "one\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "--quiet", "-m", "feature"])
    sha = String.trim(git!(repo, ["rev-parse", "HEAD"]))

    %{scope: scope, task: task, clone: clone, repo: repo, remote: remote, sha: sha}
  end

  test "mints its own token and pushes the commit as the task's branch, which the checkout then tracks", %{
    scope: scope,
    task: task,
    repo: repo,
    remote: remote,
    sha: sha
  } do
    Req.Test.expect(Client, fn conn ->
      assert conn.request_path == "/app/installations/1/access_tokens"
      Req.Test.json(conn, %{"token" => "ghs_installation_token"})
    end)

    assert :ok = Git.push_branch(scope, task, sha)
    assert git!(remote, ["rev-parse", "feature"]) == sha <> "\n"
    assert git!(repo, ["rev-parse", "origin/feature"]) == sha <> "\n"
    assert git!(repo, ["rev-parse", "--abbrev-ref", "feature@{upstream}"]) == "origin/feature\n"
    refute Git.branch_unpushed?(repo)
  end

  test "pushes the commit it is given, not one committed since", %{
    scope: scope,
    task: task,
    repo: repo,
    remote: remote,
    sha: sha
  } do
    git!(repo, ["commit", "--quiet", "--allow-empty", "-m", "after CI started"])

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
    repo: repo,
    remote: remote,
    sha: sha
  } do
    ran = Path.join(System.tmp_dir!(), "rail_push_ran_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(ran) end)
    File.mkdir_p!(ran)

    for {dir, name} <- [{repo, "checkout"}, {clone, "clone"}],
        hook <- ["pre-push", "reference-transaction", "post-checkout"] do
      path = Path.join([dir, ".git", "hooks", hook])
      File.write!(path, "#!/bin/sh\ntouch #{ran}/#{name}-#{hook}\nexit 1\n")
      File.chmod!(path, 0o755)
    end

    git!(repo, ["config", "core.fsmonitor", "touch #{ran}/fsmonitor; false"])
    git!(repo, ["config", "credential.helper", "!touch #{ran}/credential-helper; false"])
    git!(repo, ["config", "remote.origin.url", "/tmp/nowhere_#{System.unique_integer([:positive])}"])

    assert :ok = Git.push_branch(scope, task, sha)
    assert git!(remote, ["rev-parse", "feature"]) == sha <> "\n"
    assert File.ls!(ran) == []

    # A plain git in the same checkout does run them.
    System.cmd("git", ["update-ref", "refs/heads/probe", sha], cd: repo, stderr_to_stdout: true, env: [])
    assert "checkout-reference-transaction" in File.ls!(ran)
  end

  test "takes the checkout's receipt for the tree a passed CI run ran on, with the branch", %{
    scope: scope,
    task: task,
    repo: repo,
    remote: remote,
    sha: sha
  } do
    tree = String.trim(git!(repo, ["rev-parse", "#{sha}^{tree}"]))
    receipt = git!(repo, ["commit-tree", tree, "-m", "ci receipt for tree #{tree}"])
    git!(repo, ["update-ref", "refs/ci-receipts/#{tree}", String.trim(receipt)])

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
    remote: remote,
    sha: sha
  } do
    tree = String.trim(git!(repo, ["rev-parse", "#{sha}^{tree}"]))
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
    repo: repo,
    remote: remote,
    sha: sha
  } do
    tree = String.trim(git!(repo, ["rev-parse", "#{sha}^{tree}"]))
    git!(repo, ["update-ref", "refs/ci-receipts/#{tree}", sha])

    File.write!(Path.join(repo, "feature.ex"), "two\n")
    git!(repo, ["commit", "--quiet", "-am", "after CI"])
    later = String.trim(git!(repo, ["rev-parse", "HEAD"]))
    later_tree = String.trim(git!(repo, ["rev-parse", "#{later}^{tree}"]))
    git!(repo, ["update-ref", "refs/ci-receipts/#{later_tree}", later])

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
    repo: repo,
    remote: remote,
    sha: sha
  } do
    assert :ok = Git.push_branch(scope, task, sha)

    git!(repo, ["commit", "--quiet", "--amend", "-m", "feature, rewritten"])
    rewritten = String.trim(git!(repo, ["rev-parse", "HEAD"]))

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
end
