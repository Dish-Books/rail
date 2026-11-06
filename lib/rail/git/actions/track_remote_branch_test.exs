defmodule Rail.Git.Actions.TrackRemoteBranchTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.GitHub.Client
  alias Rail.Projects.Schemas.Project

  setup do
    remote = create_temp_git_repo(prefix: "rail_track_remote")
    git!(remote, ["checkout", "--quiet", "-b", "michael/rail-141-hosts"])
    git!(remote, ["commit", "--allow-empty", "-m", "built locally"])
    git!(remote, ["checkout", "--quiet", "main"])

    repo = create_temp_git_repo()
    git!(repo, ["remote", "add", "origin", remote])
    git!(repo, ["checkout", "--quiet", "--detach"])

    project = %Project{github_installation_id: 47_061, default_branch: "main", clone_path: repo}
    %{project: project, remote: remote, repo: repo}
  end

  test "points the local branch at what was pushed, tracking it, so nothing reads as unpushed", %{
    project: project,
    remote: remote,
    repo: repo
  } do
    Req.Test.expect(Client, &Req.Test.json(&1, %{"token" => "ghs_token"}))

    assert :ok = Git.track_remote_branch(project, "michael/rail-141-hosts")
    assert git!(repo, ["rev-parse", "michael/rail-141-hosts"]) == git!(remote, ["rev-parse", "michael/rail-141-hosts"])

    assert git!(repo, ["rev-parse", "--abbrev-ref", "michael/rail-141-hosts@{upstream}"]) =~
             "origin/michael/rail-141-hosts"

    worktree = Path.join(repo, ".worktrees/michael/rail-141-hosts")
    git!(repo, ["worktree", "add", worktree, "michael/rail-141-hosts"])
    refute Git.branch_unpushed?(worktree)
  end

  test "moves a branch earlier work left in the clone to what was pushed", %{project: project, remote: remote, repo: repo} do
    Req.Test.expect(Client, &Req.Test.json(&1, %{"token" => "ghs_token"}))
    git!(repo, ["branch", "michael/rail-141-hosts", "main"])

    assert :ok = Git.track_remote_branch(project, "michael/rail-141-hosts")
    assert git!(repo, ["rev-parse", "michael/rail-141-hosts"]) == git!(remote, ["rev-parse", "michael/rail-141-hosts"])
  end

  test "says what git said when the remote has no such branch", %{project: project, repo: repo} do
    Req.Test.expect(Client, &Req.Test.json(&1, %{"token" => "ghs_token"}))

    assert {:error, output} = Git.track_remote_branch(project, "gone")
    assert output =~ "couldn't find remote ref"
    refute git!(repo, ["branch", "--list", "gone"]) =~ "gone"
  end

  test "says so when GitHub will not mint a token", %{project: project} do
    Req.Test.expect(Client, &(&1 |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Not Found"})))

    assert {:error, {:github_api_error, 404, _body}} = Git.track_remote_branch(project, "michael/rail-141-hosts")
  end
end
