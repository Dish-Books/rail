defmodule Rail.Git.Actions.DeleteRemoteBranchTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.GitHub.Client
  alias Rail.Projects.Schemas.Project
  alias Rail.Tools

  setup do
    remote = create_temp_git_repo(prefix: "rail_delete_remote_branch_remote")
    git!(remote, ["branch", "rail-7-pushed"])

    repo = create_temp_git_repo()
    git!(repo, ["remote", "add", "origin", remote])

    project = %Project{github_installation_id: 47_063, default_branch: "main", clone_path: repo}
    %{project: project, remote: remote}
  end

  test "deletes the branch from origin with a token minted for the project", %{project: project, remote: remote} do
    Req.Test.expect(Client, fn conn ->
      assert conn.request_path == "/app/installations/47063/access_tokens"
      Req.Test.json(conn, %{"token" => "ghs_token"})
    end)

    assert :ok = Git.delete_remote_branch(project, "rail-7-pushed")
    assert "" = git!(remote, ["branch", "--list", "rail-7-pushed"])
  end

  test "counts a branch origin never had as deleted", %{project: project} do
    Req.Test.expect(Client, &Req.Test.json(&1, %{"token" => "ghs_token"}))

    assert :ok = Git.delete_remote_branch(project, "rail-8-never-pushed")
  end

  test "says what git said when the remote refuses the delete", %{project: project, remote: remote} do
    Req.Test.expect(Client, &Req.Test.json(&1, %{"token" => "ghs_token"}))
    hook = Path.join([remote, ".git", "hooks", "pre-receive"])
    File.write!(hook, "#!/bin/sh\necho 'Repository rule violations found' >&2\nexit 1\n")
    File.chmod!(hook, 0o755)

    assert {:error, output} = Git.delete_remote_branch(project, "rail-7-pushed")
    assert output =~ "Repository rule violations found"
    assert {_listed, 0} = Tools.run("git", ["rev-parse", "--verify", "rail-7-pushed"], cd: remote)
  end

  test "says so when GitHub will not mint a token", %{project: project} do
    Req.Test.expect(Client, &(&1 |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Not Found"})))

    assert {:error, {:github_api_error, 404, _body}} = Git.delete_remote_branch(project, "rail-7-pushed")
  end
end
