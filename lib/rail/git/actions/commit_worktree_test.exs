defmodule Rail.Git.Actions.CommitWorktreeTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Tools
  alias Rail.Users.Schemas.User

  setup %{project: project} do
    scope = system_scope()

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_cwt_1", "identifier" => "CWT-1", "title" => "Commit Worktree"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "Commit Worktree"})
    {:ok, task} = Pipeline.create_task(issue, :engineer)
    repo = create_temp_git_repo()
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: repo})
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    %{scope: scope, task: task, issue: issue, repo: repo}
  end

  test "commits as the person the ticket is assigned to", %{scope: scope, task: task, issue: issue, repo: repo} do
    {:ok, user} =
      %User{}
      |> User.changeset(%{github_id: "gh_cwt", login: "ada", name: "Ada Lovelace", email: "ada@example.com"})
      |> Repo.insert()

    {:ok, _assigned} = Issues.update_issue(issue, %{owner_user_id: user.id})
    File.write!(Path.join(repo, "feature.ex"), "one\n")

    assert {:ok, sha} = Git.commit_worktree(scope, task, "CWT-1: add feature")

    assert byte_size(sha) == 40
    assert git!(repo, ["log", "-1", "--pretty=%an <%ae>"]) =~ "Ada Lovelace <ada@example.com>"
    assert git!(repo, ["log", "-1", "--pretty=%cn <%ce>"]) =~ "Ada Lovelace <ada@example.com>"
    assert git!(repo, ["log", "-1", "--pretty=%s"]) =~ "CWT-1: add feature"
  end

  test "commits as the bot when the ticket has nobody on it", %{scope: scope, task: task, repo: repo} do
    File.write!(Path.join(repo, "feature.ex"), "one\n")

    assert {:ok, _sha} = Git.commit_worktree(scope, task, "CWT-1: add feature")
    assert git!(repo, ["log", "-1", "--pretty=%an <%ae>"]) =~ "Rail <rail[bot]@railai.dev>"
  end

  test "signs with the assignee's key when they have one", %{scope: scope, task: task, issue: issue, repo: repo} do
    key = Path.join(System.tmp_dir!(), "rail_signing_test_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(key) && File.rm_rf(key <> ".pub") end)

    {_output, 0} =
      Tools.run("ssh-keygen", ["-t", "ed25519", "-N", "", "-C", "ada@example.com", "-f", key], stderr_to_stdout: true)

    {:ok, user} =
      %User{}
      |> User.changeset(%{
        github_id: "gh_cwt_signing",
        login: "ada",
        email: "ada@example.com",
        signing_key: File.read!(key),
        signing_public_key: String.trim(File.read!(key <> ".pub"))
      })
      |> Repo.insert()

    {:ok, _assigned} = Issues.update_issue(issue, %{owner_user_id: user.id})
    File.write!(Path.join(repo, "feature.ex"), "one\n")

    assert {:ok, _sha} = Git.commit_worktree(scope, task, "CWT-1: signed")
    assert git!(repo, ["log", "-1", "--pretty=%GT"]) =~ "ssh"
  end

  test "leaves the agents' own .rail scratch out of the commit", %{scope: scope, task: task, repo: repo} do
    File.write!(Path.join(repo, "feature.ex"), "one\n")
    File.mkdir_p!(Path.join(repo, ".rail"))
    File.write!(Path.join(repo, ".rail/notes.md"), "scratch\n")

    assert {:ok, _sha} = Git.commit_worktree(scope, task, "CWT-1: add feature")

    files = git!(repo, ["show", "--name-only", "--pretty=", "HEAD"])
    assert files =~ "feature.ex"
    refute files =~ ".rail"
  end

  test "refuses a worktree with nothing in it to commit", %{scope: scope, task: task} do
    assert {:error, :nothing_to_commit} = Git.commit_worktree(scope, task, "CWT-1: nothing")
  end

  test "reports what git said when it cannot stage the tree", %{scope: scope, task: task} do
    loose = Path.join(System.tmp_dir!(), "not_a_repo_#{System.unique_integer([:positive])}")
    File.mkdir_p!(loose)
    on_exit(fn -> File.rm_rf(loose) end)

    {:ok, task} = Pipeline.update_task(task, %{worktree_path: loose})

    assert {:error, output} = Git.commit_worktree(scope, task, "CWT-1: nowhere")
    assert output =~ "not a git repository"
  end
end
