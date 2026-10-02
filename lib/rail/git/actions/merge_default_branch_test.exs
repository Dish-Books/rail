defmodule Rail.Git.Actions.MergeDefaultBranchTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project

  # The remote's main moves on past the branch, so there is something to merge in.
  setup do
    remote = create_temp_git_repo(prefix: "rail_merge_remote")
    repo = create_temp_git_repo()
    git!(repo, ["remote", "add", "origin", remote])
    git!(repo, ["fetch", "origin", "main"])
    git!(repo, ["reset", "--hard", "origin/main"])

    project =
      %Project{}
      |> Project.changeset(%{
        name: "Merge Default Branch",
        github_repo: "org/merge-default-branch",
        github_installation_id: 47_081,
        linear_team_key: "RBB",
        default_branch: "main",
        clone_path: "/tmp/repos/merge-default-branch"
      })
      |> Repo.insert!()

    issue =
      %Issue{}
      |> Issue.changeset(%{
        project_id: project.id,
        external_id: "lin_rbb",
        identifier: "RBB-1",
        title: "Merge",
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

  test "merges a branch that goes cleanly, committing as the ticket's owner", %{remote: remote, repo: repo, task: task} do
    File.write!(Path.join(remote, "upstream.txt"), "theirs\n")
    git!(remote, ["add", "."])
    git!(remote, ["commit", "-m", "upstream change"])
    File.write!(Path.join(repo, "branch.txt"), "ours\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "branch change"])
    branch_commit = git!(repo, ["rev-parse", "HEAD"])
    git!(repo, ["fetch", "origin", "main"])

    refute Git.up_to_date_with?(repo, "main")
    assert :ok = Git.merge_default_branch(system_scope(), task)
    assert Git.up_to_date_with?(repo, "main")
    assert git!(repo, ["log", "-1", "--format=%cn"]) == "Rail\n"
    # The branch's own commit is kept as it was, beneath the merge.
    assert git!(repo, ["rev-parse", "HEAD^1"]) == branch_commit
  end

  test "stops on a conflict once, and carries on once it is resolved", %{remote: remote, repo: repo, task: task} do
    File.write!(Path.join(remote, "tracked.txt"), "theirs\n")
    git!(remote, ["commit", "-am", "upstream change"])
    File.write!(Path.join(repo, "tracked.txt"), "ours\n")
    git!(repo, ["commit", "-am", "branch change"])
    File.write!(Path.join(repo, "tracked.txt"), "ours again\n")
    git!(repo, ["commit", "-am", "another branch change"])
    git!(repo, ["fetch", "origin", "main"])

    assert {:conflicts, ["tracked.txt"]} = Git.merge_default_branch(system_scope(), task)
    assert Git.merge_in_progress?(repo)
    assert Git.conflicted_files(repo) == ["tracked.txt"]
    refute Git.up_to_date_with?(repo, "main")
    # Each conflict shows what the file was before either side changed it.
    assert File.read!(Path.join(repo, "tracked.txt")) =~ "|||||||"

    File.write!(Path.join(repo, "tracked.txt"), "both\n")
    git!(repo, ["add", "tracked.txt"])

    assert :ok = Git.merge_default_branch(system_scope(), task)
    refute Git.merge_in_progress?(repo)
    assert Git.up_to_date_with?(repo, "main")
  end

  test "a merge git refuses for any other reason is abandoned and says why", %{repo: repo, task: task} do
    git!(repo, ["update-ref", "-d", "refs/remotes/origin/main"])

    assert {:error, output} = Git.merge_default_branch(system_scope(), task)
    assert output =~ "origin/main"
    refute Git.merge_in_progress?(repo)
  end
end
