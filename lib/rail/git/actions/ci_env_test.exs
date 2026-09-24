defmodule Rail.Git.Actions.CiEnvTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.GitHub.Client
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Users.Schemas.User

  setup %{project: project} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_cie_1", "identifier" => "CIE-1", "title" => "CI Env"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "CI Env"})
    {:ok, task} = Pipeline.create_task(issue, :engineer)
    repo = create_temp_git_repo()

    Req.Test.stub(Client, fn conn -> Req.Test.json(conn, %{"token" => "ghs_ci_token"}) end)

    %{project: project, issue: issue, task: task, repo: repo}
  end

  test "git acts as the ticket owner's GitHub name and email", %{project: project, issue: issue, task: task, repo: repo} do
    {:ok, user} =
      %User{}
      |> User.changeset(%{github_id: "gh_cie", login: "ada", name: "Ada Lovelace", email: "ada@example.com"})
      |> Repo.insert()

    {:ok, _assigned} = Issues.update_issue(issue, %{owner_user_id: user.id})

    assert {:ok, env} = Git.ci_env(project, task)
    assert {config, 0} = System.cmd("git", ["config", "--list"], cd: repo, env: Enum.to_list(env))
    assert config =~ "user.name=Ada Lovelace\nuser.email=ada@example.com\n"
    assert config =~ "credential.helper="
    assert env["RAIL_GIT_TOKEN"] == "ghs_ci_token"
  end

  test "git acts as the bot when the ticket has nobody on it", %{project: project, task: task, repo: repo} do
    assert {:ok, env} = Git.ci_env(project, task)
    assert {"rail[bot]@railai.dev\n", 0} = System.cmd("git", ["config", "user.email"], cd: repo, env: Enum.to_list(env))
  end
end
