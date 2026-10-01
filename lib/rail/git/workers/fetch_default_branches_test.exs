defmodule Rail.Git.Workers.FetchDefaultBranchesTest do
  use Rail.DataCase, async: true

  import ExUnit.CaptureLog

  alias Rail.Git
  alias Rail.Git.Workers.FetchDefaultBranches
  alias Rail.GitHub.Client
  alias Rail.Projects.Schemas.Project

  setup do
    stub(Git, :git_repo?, &call_original(Git, :git_repo?, [&1]))

    remote = create_temp_git_repo(prefix: "rail_fetch_all_remote")
    clone = create_temp_git_repo(prefix: "rail_fetch_all_clone")
    git!(clone, ["remote", "add", "origin", remote])
    id = System.unique_integer([:positive])

    project =
      %Project{}
      |> Project.changeset(%{
        name: "Fetch All #{id}",
        github_repo: "org/fetch-all-#{id}",
        github_installation_id: id,
        linear_team_key: "FA#{id}",
        default_branch: "main",
        clone_path: clone
      })
      |> Repo.insert!()

    %{project: project, remote: remote, clone: clone}
  end

  test "moves an active project's origin/<default_branch> to what the remote has merged", %{
    project: project,
    remote: remote,
    clone: clone
  } do
    installation_path = "/app/installations/#{project.github_installation_id}/access_tokens"

    Req.Test.expect(Client, fn conn ->
      assert conn.request_path == installation_path
      Req.Test.json(conn, %{"token" => "ghs_token"})
    end)

    File.write!(Path.join(remote, "merged.txt"), "merged\n")
    git!(remote, ["add", "."])
    git!(remote, ["commit", "-m", "a merge"])

    assert :ok = FetchDefaultBranches.perform(%Oban.Job{args: %{}})
    assert git!(clone, ["rev-parse", "origin/main"]) == git!(remote, ["rev-parse", "main"])
  end

  test "leaves an inactive project's clone alone", %{project: project} do
    project |> Project.changeset(%{active: false}) |> Repo.update!()

    assert :ok = FetchDefaultBranches.perform(%Oban.Job{args: %{}})
    assert {:error, _output} = Git.read_default_branch_file(project, "tracked.txt")
  end

  test "stays :ok and names the project when a fetch fails, so the rest still run", %{
    project: project,
    clone: clone
  } do
    Req.Test.expect(Client, &Req.Test.json(&1, %{"token" => "ghs_token"}))
    git!(clone, ["remote", "set-url", "origin", "/tmp/nowhere_#{System.unique_integer([:positive])}"])

    assert capture_log(fn -> assert :ok = FetchDefaultBranches.perform(%Oban.Job{args: %{}}) end) =~ project.name
  end
end
