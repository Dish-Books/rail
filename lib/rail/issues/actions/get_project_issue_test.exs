defmodule Rail.Issues.Actions.GetProjectIssueTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Workers.SyncIssue
  alias Rail.Projects

  setup do
    key = "Imp-#{System.unique_integer([:positive])}"

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Looked up",
        github_repo: "example/#{key}",
        github_installation_id: 1,
        key: key,
        default_branch: "main",
        clone_path: "/tmp/#{key}"
      })

    %{project: project, key: key}
  end

  test "an issue saved under its identifier comes back by it", %{project: project, key: key} do
    identifier = "#{key}-401"

    %Issue{id: issue_id} =
      Repo.insert!(%Issue{
        project_id: project.id,
        identifier: identifier,
        title: "Have",
        state: :todo
      })

    assert {:ok, %Issue{id: ^issue_id}} = Issues.get_project_issue(project, identifier)
  end

  test "finds an issue by its identifier in any case, or by its number, and nowhere else", %{
    project: project,
    key: key
  } do
    {:ok, _first} = Issues.create_issue(system_scope(), project, %{title: "First"})
    {:ok, %Issue{id: issue_id}} = Issues.create_issue(system_scope(), project, %{title: "Second"})

    assert {:ok, %Issue{id: ^issue_id}} = Issues.get_project_issue(project, String.downcase(key) <> "-2")
    assert {:ok, %Issue{id: ^issue_id}} = Issues.get_project_issue(project, String.upcase(key) <> "-02")
    assert {:ok, %Issue{id: ^issue_id}} = Issues.get_project_issue(project, "2")
    assert {:error, :not_found} = Issues.get_project_issue(project, "OTHER-2")
    assert {:error, :not_found} = Issues.get_project_issue(project, key <> "-two")
    assert {:error, :not_found} = Issues.get_project_issue(project, key <> "-3")
    refute_enqueued(worker: SyncIssue)
  end
end
