defmodule Rail.Git.Actions.FetchBranchTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.GitHub.Client
  alias Rail.Projects.Schemas.Project
  alias Rail.Tools

  setup do
    remote = create_temp_git_repo(prefix: "rail_fetch_branch_remote")
    git!(remote, ["checkout", "--quiet", "-b", "outside/work"])
    File.write!(Path.join(remote, "work.ex"), "work\n")
    git!(remote, ["add", "."])
    git!(remote, ["commit", "-m", "Work done outside Rail"])

    repo = create_temp_git_repo()
    git!(repo, ["remote", "add", "origin", remote])

    # A task's clone being made: the project's clone is somewhere else, and is never written.
    clone = create_temp_git_repo(prefix: "rail_fetch_branch_project")
    project = %Project{github_installation_id: 47_062, default_branch: "main", clone_path: clone}
    %{project: project, remote: remote, repo: repo, clone: clone}
  end

  test "fetches the branch into the repository given, with a token minted for the project, tracking nothing",
       %{project: project, remote: remote, repo: repo, clone: clone} do
    Req.Test.expect(Client, fn conn ->
      assert conn.request_path == "/app/installations/47062/access_tokens"
      Req.Test.json(conn, %{"token" => "ghs_token"})
    end)

    assert :ok = Git.fetch_branch(project, repo, "outside/work")
    assert git!(repo, ["rev-parse", "outside/work"]) == git!(remote, ["rev-parse", "outside/work"])
    assert git!(repo, ["rev-parse", "origin/outside/work"]) == git!(remote, ["rev-parse", "outside/work"])

    assert {_no_upstream, 128} =
             Tools.run("git", ["rev-parse", "--abbrev-ref", "outside/work@{upstream}"], cd: repo, stderr_to_stdout: true)

    refute git!(clone, ["branch", "--all"]) =~ "outside/work"
  end

  test "moves a local branch left behind to where the remote has it", %{project: project, remote: remote, repo: repo} do
    Req.Test.expect(Client, &Req.Test.json(&1, %{"token" => "ghs_token"}))
    git!(repo, ["branch", "outside/work"])

    assert :ok = Git.fetch_branch(project, repo, "outside/work")
    assert git!(repo, ["rev-parse", "outside/work"]) == git!(remote, ["rev-parse", "outside/work"])
  end

  test "says what git said when the remote has no such branch", %{project: project, repo: repo} do
    Req.Test.expect(Client, &Req.Test.json(&1, %{"token" => "ghs_token"}))

    assert {:error, output} = Git.fetch_branch(project, repo, "nowhere")
    assert output =~ "couldn't find remote ref"
  end

  test "says so when GitHub will not mint a token", %{project: project, repo: repo} do
    Req.Test.expect(Client, &(&1 |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Not Found"})))

    assert {:error, {:github_api_error, 404, _body}} = Git.fetch_branch(project, repo, "outside/work")
  end
end
