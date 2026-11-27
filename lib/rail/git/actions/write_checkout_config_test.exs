defmodule Rail.Git.Actions.WriteCheckoutConfigTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.GitHub.Client
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Projects
  alias Rail.Tools
  alias Rail.Users.Schemas.User

  # As Rail lays them out: origin, the project's clone of it, and the task's checkout, a clone of the clone.
  setup do
    scope = system_scope()
    unique = System.unique_integer([:positive])
    remote = create_temp_git_repo(prefix: "rail_wcc_remote")
    git!(remote, ["config", "receive.denyCurrentBranch", "ignore"])
    clone = Path.join(System.tmp_dir!(), "rail_wcc_clone_#{unique}")
    on_exit(fn -> File.rm_rf(clone) end)
    git!(System.tmp_dir!(), ["clone", "--quiet", remote, clone])

    {:ok, project} =
      Projects.create_project(scope, %{
        name: "Checkout Config #{unique}",
        github_repo: "example/wcc-#{unique}",
        github_installation_id: 1,
        default_branch: "main",
        key: "WCC#{unique}",
        clone_path: clone
      })

    {:ok, issue} = Issues.create_issue(scope, project, %{title: "Issue", description: "Write Checkout Config"})
    {:ok, task} = Pipeline.create_task(issue, :engineer)
    on_exit(fn -> Enum.each([Path.dirname(task.worktree_path), task.scratch_path], &File.rm_rf/1) end)
    Req.Test.stub(Client, &Req.Test.json(&1, %{"token" => "ghs_installation_token"}))
    {:ok, checkout} = Git.get_or_create_worktree(project, task)

    # CI runs these tests with its own identity in GIT_CONFIG_* variables, which outrank every config file.
    commit = fn path, message ->
      {_output, 0} =
        Tools.run("git", ["commit", "--allow-empty", "-m", message],
          cd: path,
          env: %{"GIT_CONFIG_COUNT" => "0"},
          stderr_to_stdout: true
        )
    end

    ran = Path.join(System.tmp_dir!(), "rail_wcc_ran_#{unique}")
    File.mkdir_p!(ran)
    on_exit(fn -> File.rm_rf(ran) end)

    %{
      scope: scope,
      project: project,
      issue: issue,
      task: task,
      remote: remote,
      clone: clone,
      checkout: checkout,
      commit: commit,
      ran: ran
    }
  end

  test "the checkout commits as the person the ticket is assigned to", %{
    project: project,
    task: task,
    issue: issue,
    checkout: checkout,
    commit: commit
  } do
    {:ok, user} =
      %User{}
      |> User.changeset(%{
        github_id: "gh_wcc",
        login: "ada-write-checkout-config",
        name: "Ada Lovelace",
        email: "ada-write-checkout-config@example.com"
      })
      |> Repo.insert()

    {:ok, _assigned} = Issues.update_issue(issue, %{owner_user_id: user.id})

    assert :ok = Git.write_checkout_config(project, task)

    commit.(checkout, "WCC-1: the work")

    assert git!(checkout, ["log", "-1", "--pretty=%an <%ae>|%cn <%ce>"]) ==
             "Ada Lovelace <ada-write-checkout-config@example.com>|" <>
               "Ada Lovelace <ada-write-checkout-config@example.com>\n"

    refute git!(checkout, ["cat-file", "commit", "HEAD"]) =~ "SSH SIGNATURE"
  end

  test "the checkout commits as the bot, unsigned, when the ticket has nobody on it", %{
    project: project,
    task: task,
    checkout: checkout,
    commit: commit
  } do
    git!(checkout, ["config", "commit.gpgsign", "true"])

    assert :ok = Git.write_checkout_config(project, task)

    commit.(checkout, "WCC-1: the work")
    assert git!(checkout, ["log", "-1", "--pretty=%an <%ae>"]) == "Rail <rail[bot]@railai.dev>\n"
  end

  test "the checkout signs with the assignee's key, kept where only they can read it", %{
    project: project,
    task: task,
    issue: issue,
    checkout: checkout,
    commit: commit
  } do
    key = Path.join(System.tmp_dir!(), "rail_signing_test_#{System.unique_integer([:positive])}")

    on_exit(fn ->
      File.rm_rf(key)
      File.rm_rf(key <> ".pub")
    end)

    {_output, 0} =
      Tools.run("ssh-keygen", ["-t", "ed25519", "-N", "", "-C", "ada-write-checkout-config@example.com", "-f", key],
        stderr_to_stdout: true
      )

    {:ok, user} =
      %User{}
      |> User.changeset(%{
        github_id: "gh_wcc_signing",
        login: "ada-write-checkout-config",
        email: "ada-write-checkout-config@example.com",
        signing_key: File.read!(key),
        signing_public_key: String.trim(File.read!(key <> ".pub"))
      })
      |> Repo.insert()

    {:ok, _assigned} = Issues.update_issue(issue, %{owner_user_id: user.id})

    # Written twice, as two turns in a row do, so the key is written over rather than refused as already there.
    assert :ok = Git.write_checkout_config(project, task)
    assert :ok = Git.write_checkout_config(project, task)

    commit.(checkout, "WCC-1: signed")
    # The signature is read rather than verified: verifying needs the machine's own `gpg.ssh.allowedSignersFile`.
    assert git!(checkout, ["cat-file", "commit", "HEAD"]) =~ "-----BEGIN SSH SIGNATURE-----"
    assert %File.Stat{mode: mode} = File.stat!(Path.join([task.scratch_path, ".signing", "key"]))
    assert Bitwise.band(mode, 0o777) == 0o600
  end

  # Before its sandbox mounted the config read-only, a sandbox could write anything there.
  test "the config is Rail's whole: nothing a sandbox wrote there is kept, and the repository still reads", %{
    project: project,
    task: task,
    remote: remote,
    checkout: checkout,
    ran: ran
  } do
    config = Path.join(checkout, ".git/config")
    included = Path.join(checkout, ".git/included")
    File.write!(included, "[core]\n\tfsmonitor = touch #{ran}/included\n")

    for {key, value} <- [
          {"filter.planted.clean", "touch #{ran}/filter; cat"},
          {"merge.planted.driver", "touch #{ran}/merge; false"},
          {"hook.planted.command", "touch #{ran}/hook"},
          {"hook.planted.event", "reference-transaction"},
          {"core.sshCommand", "touch #{ran}/ssh"},
          {"remote.origin.url", "/tmp/nowhere"},
          {"include.path", included},
          {"extensions.worktreeConfig", "true"}
        ],
        do: git!(checkout, ["config", "--file", config, key, value])

    File.write!(Path.join(checkout, ".git/config.worktree"), "[core]\n\tfsmonitor = touch #{ran}/worktree\n")

    assert :ok = Git.write_checkout_config(project, task)

    written = File.read!(config)
    refute written =~ "planted"
    refute written =~ ran
    refute written =~ "nowhere"
    refute written =~ "include"
    refute written =~ "worktreeConfig"
    refute File.exists?(Path.join(checkout, ".git/config.worktree"))
    assert [] = Path.wildcard(config <> ".rail*")

    assert git!(checkout, ["config", "--file", config, "remote.origin.url"]) == remote <> "\n"
    assert git!(checkout, ["config", "--file", config, "extensions.objectformat"]) == "sha1\n"
    assert git!(checkout, ["branch", "--show-current"]) == task.worktree_name <> "\n"
    assert git!(checkout, ["status", "--porcelain"]) == ""
  end

  test "keeps the branch tracking origin's when Rail recorded it so, and only then", %{
    project: project,
    task: %{worktree_name: branch} = task,
    checkout: checkout
  } do
    assert :ok = Git.write_checkout_config(project, task)
    assert {_none, 1} = Tools.run("git", ["config", "branch.#{branch}.merge"], cd: checkout)

    git!(checkout, ["config", "branch.#{branch}.remote", "origin"])
    git!(checkout, ["config", "branch.#{branch}.merge", "refs/heads/#{branch}"])
    assert :ok = Git.write_checkout_config(project, task)
    assert git!(checkout, ["config", "branch.#{branch}.merge"]) == "refs/heads/#{branch}\n"
    assert git!(checkout, ["config", "branch.#{branch}.remote"]) == "origin\n"

    git!(checkout, ["config", "branch.#{branch}.merge", "refs/heads/elsewhere"])
    assert :ok = Git.write_checkout_config(project, task)
    assert {_none, 1} = Tools.run("git", ["config", "branch.#{branch}.merge"], cd: checkout)
  end

  # A filter, a merge driver and a config hook are each named under a name of the checkout's own choosing, which no
  # override of Rail's can reach; only the config being Rail's does.
  test "Rail's status, diff, merge-tree and push run none of the filter, merge driver or hook a checkout defined first",
       %{scope: scope, project: project, task: task, remote: remote, checkout: checkout, ran: ran} do
    File.write!(Path.join(checkout, ".git/info/attributes"), "* filter=planted merge=planted\n")

    for {key, value} <- [
          {"filter.planted.clean", "touch #{ran}/filter; cat"},
          {"merge.planted.driver", "touch #{ran}/merge; false"},
          {"hook.planted.command", "touch #{ran}/hook"},
          {"hook.planted.event", "reference-transaction"}
        ],
        do: git!(checkout, ["config", key, value])

    # The branch and origin's default branch both change one file, so a merge of them needs its driver.
    File.write!(Path.join(remote, "tracked.txt"), "theirs\n")
    git!(remote, ["commit", "--quiet", "-am", "theirs"])
    File.write!(Path.join(checkout, "tracked.txt"), "ours\n")
    git!(checkout, ["commit", "--quiet", "-am", "ours"])
    sha = String.trim(git!(checkout, ["rev-parse", "HEAD"]))
    :ok = Git.fetch_default_branch(project, checkout)
    File.write!(Path.join(checkout, "tracked.txt"), "ours, changed\n")

    # A plain git here runs them.
    for args <- [["status", "--porcelain"], ["merge-tree", "--write-tree", "HEAD", "origin/main"]],
        do: System.cmd("git", args, cd: checkout, stderr_to_stdout: true, env: [])

    assert "filter" in File.ls!(ran)
    assert "merge" in File.ls!(ran)
    Enum.each(File.ls!(ran), &File.rm!(Path.join(ran, &1)))

    assert :ok = Git.write_checkout_config(project, task)

    assert Git.worktree_dirty?(checkout)
    assert %{head_sha: ^sha} = Git.branch_fingerprint(checkout)
    assert "tracked.txt" in Git.list_changed_paths(checkout)
    assert %{head_sha: ^sha} = Git.content_fingerprint(checkout)
    assert %{behind: true, conflicts: ["tracked.txt"]} = Git.base_status(checkout, "main")
    assert :ok = Git.push_branch(scope, task, sha)
    assert git!(remote, ["rev-parse", task.worktree_name]) == sha <> "\n"

    assert File.ls!(ran) == []
  end

  test "a task still on a worktree of its project's clone commits as its owner, and no other worktree does", %{
    project: project,
    task: task,
    issue: issue,
    clone: clone,
    commit: commit
  } do
    worktree = Path.join(clone, ".worktrees/wcc-legacy")
    git!(clone, ["config", "user.name", "Rail Test"])
    git!(clone, ["config", "user.email", "test@rail.local"])
    git!(clone, ["config", "commit.gpgsign", "false"])
    git!(clone, ["worktree", "add", "--quiet", "-b", "wcc-legacy", worktree])

    {:ok, user} =
      %User{}
      |> User.changeset(%{
        github_id: "gh_wcc_legacy",
        login: "ada-wcc-legacy",
        name: "Ada Lovelace",
        email: "ada-wcc-legacy@example.com"
      })
      |> Repo.insert()

    {:ok, _assigned} = Issues.update_issue(issue, %{owner_user_id: user.id})

    assert :ok = Git.write_checkout_config(project, %{task | worktree_path: worktree})

    commit.(worktree, "WCC-1: the work")
    assert git!(worktree, ["log", "-1", "--pretty=%an <%ae>"]) == "Ada Lovelace <ada-wcc-legacy@example.com>\n"

    commit.(clone, "someone else's")
    assert git!(clone, ["log", "-1", "--pretty=%an"]) == "Rail Test\n"
  end

  test "says what git said when it cannot write the config", %{project: project, task: task, clone: clone} do
    loose = Path.join(System.tmp_dir!(), "rail_wcc_loose_#{System.unique_integer([:positive])}")
    File.mkdir_p!(loose)
    on_exit(fn -> File.rm_rf(loose) end)

    assert {:error, output} = Git.write_checkout_config(project, %{task | worktree_path: loose})
    assert output =~ "not in a git directory"

    git!(clone, ["remote", "remove", "origin"])
    assert {:error, output} = Git.write_checkout_config(project, task)
    assert output =~ "No such remote"
  end
end
