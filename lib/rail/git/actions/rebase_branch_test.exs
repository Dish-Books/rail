defmodule Rail.Git.Actions.RebaseBranchTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project

  # The remote's main moves on past the branch, so there is something to rebase onto.
  setup do
    remote = create_temp_git_repo(prefix: "rail_rebase_remote")
    repo = create_temp_git_repo()
    git!(repo, ["remote", "add", "origin", remote])
    git!(repo, ["fetch", "origin", "main"])
    git!(repo, ["reset", "--hard", "origin/main"])

    project =
      %Project{}
      |> Project.changeset(%{
        name: "Rebase Branch",
        github_repo: "org/rebase-branch",
        github_installation_id: 47_081,
        linear_team_key: "RBB",
        default_branch: "main",
        clone_path: "/tmp/repos/rebase-branch"
      })
      |> Repo.insert!()

    issue =
      %Issue{}
      |> Issue.changeset(%{
        project_id: project.id,
        external_id: "lin_rbb",
        identifier: "RBB-1",
        title: "Rebase",
        state: :backlog
      })
      |> Repo.insert!()

    task =
      %Task{}
      |> Task.changeset(
        %{issue_id: issue.id, stage: :review, worktree_name: "rbb-1", worktree_path: repo, scratch_path: "/tmp/rbb"},
        project.id
      )
      |> Repo.insert!()

    %{remote: remote, repo: repo, task: task}
  end

  test "rebases a branch that goes cleanly, committing as the ticket's owner", %{remote: remote, repo: repo, task: task} do
    File.write!(Path.join(remote, "upstream.txt"), "theirs\n")
    git!(remote, ["add", "."])
    git!(remote, ["commit", "-m", "upstream change"])
    File.write!(Path.join(repo, "branch.txt"), "ours\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "branch change"])
    git!(repo, ["fetch", "origin", "main"])

    refute Git.rebased_onto?(repo, "main")
    assert :ok = Git.rebase_branch(system_scope(), task)
    assert Git.rebased_onto?(repo, "main")
    assert git!(repo, ["log", "-1", "--format=%cn"]) == "Rail\n"
  end

  test "stops on a conflict, and carries on once it is resolved", %{remote: remote, repo: repo, task: task} do
    File.write!(Path.join(remote, "tracked.txt"), "theirs\n")
    git!(remote, ["commit", "-am", "upstream change"])
    File.write!(Path.join(repo, "tracked.txt"), "ours\n")
    git!(repo, ["commit", "-am", "branch change"])
    git!(repo, ["fetch", "origin", "main"])

    assert {:conflicts, ["tracked.txt"]} = Git.rebase_branch(system_scope(), task)
    assert Git.rebase_in_progress?(repo)
    assert Git.conflicted_files(repo) == ["tracked.txt"]
    refute Git.rebased_onto?(repo, "main")

    File.write!(Path.join(repo, "tracked.txt"), "both\n")
    git!(repo, ["add", "tracked.txt"])

    assert :ok = Git.rebase_branch(system_scope(), task)
    refute Git.rebase_in_progress?(repo)
    assert Git.rebased_onto?(repo, "main")
  end

  test "a rebase git refuses for any other reason is abandoned and says why", %{repo: repo, task: task} do
    git!(repo, ["update-ref", "-d", "refs/remotes/origin/main"])

    assert {:error, output} = Git.rebase_branch(system_scope(), task)
    assert output =~ "origin/main"
    refute Git.rebase_in_progress?(repo)
  end
end
