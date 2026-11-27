defmodule Rail.Git.Actions.CiEnvTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Users.Schemas.User

  setup %{project: project} do
    {:ok, issue} = Issues.create_issue(system_scope(), project, %{title: "Issue", description: "CI Env"})
    {:ok, task} = Pipeline.create_task(issue, :engineer)
    repo = create_temp_git_repo()

    %{project: project, issue: issue, task: task, repo: repo}
  end

  test "git acts as the ticket owner's GitHub name and email", %{project: project, issue: issue, task: task, repo: repo} do
    {:ok, user} =
      %User{}
      |> User.changeset(%{
        github_id: "gh_cie",
        login: "ada-ci-env",
        name: "Ada Lovelace",
        email: "ada-ci-env@example.com"
      })
      |> Repo.insert()

    {:ok, _assigned} = Issues.update_issue(issue, %{owner_user_id: user.id})

    assert {:ok, env} = Git.ci_env(project, task)
    assert {config, 0} = System.cmd("git", ["config", "--list"], cd: repo, env: Enum.to_list(env))
    assert config =~ "user.name=Ada Lovelace\nuser.email=ada-ci-env@example.com\n"
  end

  # CI runs scripts an agent wrote, so it gets nothing to push with: Rail pushes the receipt it leaves.
  test "gives CI no credential to push with, and says Rail pushes its receipt", %{project: project, task: task} do
    reject(&Git.credential_env/1)

    assert {:ok, env} = Git.ci_env(project, task)
    assert env["RAIL_PUSHES_RECEIPT"] == "1"
    refute Map.has_key?(env, "RAIL_GIT_TOKEN")
    refute env |> Map.values() |> Enum.any?(&(&1 =~ "credential"))
  end

  test "git acts as the bot when the ticket has nobody on it", %{project: project, task: task, repo: repo} do
    assert {:ok, env} = Git.ci_env(project, task)
    assert {"rail[bot]@railai.dev\n", 0} = System.cmd("git", ["config", "user.email"], cd: repo, env: Enum.to_list(env))
  end
end
