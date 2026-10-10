defmodule Rail.Git.Actions.SetCommitIdentityTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Tools
  alias Rail.Users.Schemas.User

  setup %{project: project} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_sci_1", "identifier" => "SCI-1", "title" => "Set Commit Identity"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Set Commit Identity"})
    {:ok, task} = Pipeline.create_task(issue, :engineer)
    clone = create_temp_git_repo()
    worktree = Path.join(clone, ".worktrees/sci-1")
    git!(clone, ["worktree", "add", "--quiet", "-b", "sci-1", worktree])
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: worktree})
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    # CI runs these tests with its own identity in GIT_CONFIG_* variables, which outrank every config file.
    commit = fn path, message ->
      {_output, 0} =
        Tools.run("git", ["commit", "--allow-empty", "-m", message],
          cd: path,
          env: %{"GIT_CONFIG_COUNT" => "0"},
          stderr_to_stdout: true
        )
    end

    %{task: task, issue: issue, clone: clone, worktree: worktree, commit: commit}
  end

  test "the worktree commits as the person the ticket is assigned to, and no other worktree does", %{
    task: task,
    issue: issue,
    clone: clone,
    worktree: worktree,
    commit: commit
  } do
    {:ok, user} =
      %User{}
      |> User.changeset(%{github_id: "gh_sci", login: "ada", name: "Ada Lovelace", email: "ada@example.com"})
      |> Repo.insert()

    {:ok, _assigned} = Issues.update_issue(issue, %{owner_user_id: user.id})

    assert :ok = Git.set_commit_identity(task)

    commit.(worktree, "SCI-1: the work")

    assert git!(worktree, ["log", "-1", "--pretty=%an <%ae>|%cn <%ce>"]) ==
             "Ada Lovelace <ada@example.com>|Ada Lovelace <ada@example.com>\n"

    assert git!(worktree, ["cat-file", "commit", "HEAD"]) =~ "\n\nSCI-1: the work"
    refute git!(worktree, ["cat-file", "commit", "HEAD"]) =~ "SSH SIGNATURE"

    commit.(clone, "someone else's")
    assert git!(clone, ["log", "-1", "--pretty=%an"]) == "Rail Test\n"
  end

  test "the worktree commits as the bot, unsigned, when the ticket has nobody on it", %{
    task: task,
    worktree: worktree,
    commit: commit
  } do
    git!(worktree, ["config", "--local", "commit.gpgsign", "true"])

    assert :ok = Git.set_commit_identity(task)

    commit.(worktree, "SCI-1: the work")
    assert git!(worktree, ["log", "-1", "--pretty=%an <%ae>"]) == "Rail <rail[bot]@railai.dev>\n"
  end

  test "the worktree signs with the assignee's key, kept where only they can read it", %{
    task: task,
    issue: issue,
    worktree: worktree,
    commit: commit
  } do
    key = Path.join(System.tmp_dir!(), "rail_signing_test_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(key) && File.rm_rf(key <> ".pub") end)

    {_output, 0} =
      Tools.run("ssh-keygen", ["-t", "ed25519", "-N", "", "-C", "ada@example.com", "-f", key], stderr_to_stdout: true)

    {:ok, user} =
      %User{}
      |> User.changeset(%{
        github_id: "gh_sci_signing",
        login: "ada",
        email: "ada@example.com",
        signing_key: File.read!(key),
        signing_public_key: String.trim(File.read!(key <> ".pub"))
      })
      |> Repo.insert()

    {:ok, _assigned} = Issues.update_issue(issue, %{owner_user_id: user.id})

    # Set twice, as two turns in a row do, so the key is written over rather than refused as already there.
    assert :ok = Git.set_commit_identity(task)
    assert :ok = Git.set_commit_identity(task)

    commit.(worktree, "SCI-1: signed")
    # The signature is read rather than verified: verifying needs the machine's own `gpg.ssh.allowedSignersFile`.
    assert git!(worktree, ["cat-file", "commit", "HEAD"]) =~ "-----BEGIN SSH SIGNATURE-----"
    assert %File.Stat{mode: mode} = File.stat!(Path.join([task.scratch_path, ".signing", "key"]))
    assert Bitwise.band(mode, 0o777) == 0o600
  end

  test "says what git said when it cannot write the config", %{task: task} do
    loose = Path.join(System.tmp_dir!(), "rail_sci_loose_#{System.unique_integer([:positive])}")
    File.mkdir_p!(loose)
    on_exit(fn -> File.rm_rf(loose) end)

    assert {:error, output} = Git.set_commit_identity(%{task | worktree_path: loose})
    assert output =~ "not in a git directory"
  end
end
