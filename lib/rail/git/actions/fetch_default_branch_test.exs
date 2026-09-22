defmodule Rail.Git.Actions.FetchDefaultBranchTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.GitHub.Client
  alias Rail.Projects.Schemas.Project

  setup do
    remote = create_temp_git_repo(prefix: "rail_fetch_remote")
    repo = create_temp_git_repo()
    git!(repo, ["remote", "add", "origin", remote])

    %{project: %Project{github_installation_id: 47_061, default_branch: "main"}, remote: remote, repo: repo}
  end

  test "fetches the default branch with a token minted for the project", %{
    project: project,
    remote: remote,
    repo: repo
  } do
    Req.Test.expect(Client, fn conn ->
      assert conn.request_path == "/app/installations/47061/access_tokens"
      Req.Test.json(conn, %{"token" => "ghs_token"})
    end)

    assert :ok = Git.fetch_default_branch(project, repo)
    assert git!(repo, ["rev-parse", "origin/main"]) == git!(remote, ["rev-parse", "main"])
  end

  test "says what git said when the fetch fails", %{project: project, repo: repo} do
    Req.Test.expect(Client, &Req.Test.json(&1, %{"token" => "ghs_token"}))
    git!(repo, ["remote", "set-url", "origin", "/tmp/nowhere_#{System.unique_integer([:positive])}"])

    assert {:error, output} = Git.fetch_default_branch(project, repo)
    assert output =~ "does not appear to be a git repository"
  end

  test "says so when GitHub will not mint a token", %{project: project, repo: repo} do
    Req.Test.expect(Client, &(&1 |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Not Found"})))

    assert {:error, {:github_api_error, 404, _body}} = Git.fetch_default_branch(project, repo)
  end
end
