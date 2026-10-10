defmodule Rail.Git.Actions.ClearCommitIdentityTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Users.Schemas.User

  setup %{project: project} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_cci_1", "identifier" => "CCI-1", "title" => "Clear Commit Identity"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Clear Commit Identity"})
    {:ok, task} = Pipeline.create_task(issue, :engineer)
    clone = create_temp_git_repo()
    worktree = Path.join(clone, ".worktrees/cci-1")
    git!(clone, ["worktree", "add", "--quiet", "-b", "cci-1", worktree])
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: worktree})
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    %{task: task, issue: issue, worktree: worktree}
  end

  test "takes the turn's identity and key out, so the worktree commits as the clone does again", %{
    task: task,
    issue: issue,
    worktree: worktree
  } do
    {:ok, user} =
      %User{}
      |> User.changeset(%{
        github_id: "gh_cci",
        login: "ada",
        name: "Ada Lovelace",
        email: "ada@example.com",
        signing_key: "not a real key",
        signing_public_key: "ssh-ed25519 AAAA ada@example.com"
      })
      |> Repo.insert()

    {:ok, _assigned} = Issues.update_issue(issue, %{owner_user_id: user.id})
    :ok = Git.set_commit_identity(task)
    key = Path.join([task.scratch_path, ".signing", "key"])
    assert File.exists?(key)

    assert :ok = Git.clear_commit_identity(task)

    refute File.exists?(key)
    refute File.exists?(key <> ".pub")
    assert git!(worktree, ["config", "--worktree", "--list"]) == ""
    git!(worktree, ["commit", "--allow-empty", "-m", "after the turn"])
    assert git!(worktree, ["log", "-1", "--pretty=%an"]) == "Rail Test\n"
  end

  # Without the extension `--worktree` writes to the clone's config, which a turn never set.
  test "leaves a worktree no turn set up alone", %{task: task, worktree: worktree} do
    assert :ok = Git.clear_commit_identity(task)
    assert git!(worktree, ["config", "user.name"]) == "Rail Test\n"
  end

  test "is done with a worktree that is gone", %{task: task} do
    assert :ok = Git.clear_commit_identity(%{task | worktree_path: "/nonexistent/cci"})
  end
end
