defmodule Rail.Issues.Actions.GetIssueTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  test "get_issue/1 finds an issue by Rail's id or Linear's, with its project" do
    {:ok, %Project{id: project_id}} =
      Projects.create_project(system_scope(), %{
        name: "Get Issue Project",
        github_repo: "org/get-issue",
        github_installation_id: 5101,
        linear_team_id: "team_get_issue",
        linear_team_key: "GTI",
        default_branch: "main",
        clone_path: "/tmp/repos/get-issue"
      })

    %Issue{id: issue_id} =
      %Issue{}
      |> Issue.changeset(%{
        project_id: project_id,
        external_id: "lin_get_1",
        identifier: "GTI-1",
        title: "Get Issue Test",
        state: :triage
      })
      |> Repo.insert!()

    assert {:ok, %Issue{id: ^issue_id, project: %Project{id: ^project_id}}} = Issues.get_issue(issue_id)
    assert {:ok, %Issue{id: ^issue_id}} = Issues.get_issue("lin_get_1")
  end

  test "get_issue/1 returns {:error, :not_found} when issue does not exist" do
    assert {:error, :not_found} = Issues.get_issue("iss_nonexistent")
  end
end
