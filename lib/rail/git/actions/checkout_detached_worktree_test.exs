defmodule Rail.Git.Actions.CheckoutDetachedWorktreeTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.GitHub.Client
  alias Rail.Projects.Schemas.Project

  setup do
    Req.Test.stub(Client, &Req.Test.json(&1, %{"token" => "ghs_token"}))
    remote = create_temp_git_repo(prefix: "rail_detached_remote")
    repo = create_temp_git_repo()
    git!(repo, ["remote", "add", "origin", remote])

    %{remote: remote, repo: repo, project: %Project{clone_path: repo, default_branch: "main", github_installation_id: 1}}
  end

  test "checks out origin's default branch detached, fetched first", %{remote: remote, repo: repo, project: project} do
    File.write!(Path.join(remote, "upstream.txt"), "merged since the clone\n")
    git!(remote, ["add", "."])
    git!(remote, ["commit", "-m", "upstream commit"])
    path = Path.join(repo, ".worktrees/triage-1")

    assert {:ok, ^path} = Git.checkout_detached_worktree(project, path)

    assert git!(path, ["rev-parse", "HEAD"]) == git!(remote, ["rev-parse", "main"])
    assert {_branch, 1} = Rail.Tools.run("git", ["symbolic-ref", "-q", "HEAD"], cd: path)
  end

  test "replaces a stale worktree left at the path", %{remote: remote, repo: repo, project: project} do
    path = Path.join(repo, ".worktrees/triage-2")
    assert {:ok, ^path} = Git.checkout_detached_worktree(project, path)
    File.write!(Path.join(path, "leftover.txt"), "from the last pass\n")

    File.write!(Path.join(remote, "newer.txt"), "newer\n")
    git!(remote, ["add", "."])
    git!(remote, ["commit", "-m", "newer"])

    assert {:ok, ^path} = Git.checkout_detached_worktree(project, path)
    refute File.exists?(Path.join(path, "leftover.txt"))
    assert File.exists?(Path.join(path, "newer.txt"))
  end

  test "says what git said when origin has no such branch", %{repo: repo, project: project} do
    assert {:error, reason} =
             Git.checkout_detached_worktree(%{project | default_branch: "primary"}, Path.join(repo, ".worktrees/t3"))

    assert reason =~ "couldn't find remote ref primary"
  end

  test "says what git said when the worktree cannot be added", %{repo: repo, project: project} do
    blocker = Path.join(repo, ".worktrees/blocked")
    File.mkdir_p!(Path.dirname(blocker))
    File.write!(blocker, "a file where the worktree should go")

    assert {:error, reason} = Git.checkout_detached_worktree(project, blocker)
    assert reason =~ "Failed to create worktree at #{blocker}"
  end
end
