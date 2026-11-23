defmodule Rail.Issues.Actions.FindIssueTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects
  alias Rail.Projects.Schemas.Project

  setup do
    key = "Fnd#{System.unique_integer([:positive])}"

    {:ok, local} =
      Projects.create_project(system_scope(), %{
        name: "Found here",
        github_repo: "example/#{key}",
        github_installation_id: 1,
        key: key,
        default_branch: "main",
        clone_path: "/tmp/#{key}"
      })

    {:ok, issue} = Issues.create_issue(system_scope(), local, %{title: "Look me up"})
    %{local: local, issue: issue}
  end

  test "finds a ticket by its identifier in any case, with its project and the preloads asked for", %{
    local: %Project{id: project_id} = local,
    issue: %Issue{id: issue_id, identifier: identifier}
  } do
    scope = user_scope(project_ids: [project_id])

    assert {:ok, %Issue{id: ^issue_id, project: %Project{id: ^project_id}, comments: []}} =
             Issues.find_issue(scope, " #{String.downcase(identifier)} ", preload: [:comments])

    [_key, number] = String.split(identifier, "-")
    assert {:ok, %Issue{id: ^issue_id}} = Issues.find_issue(scope, "#{local.key}##{number}")
    assert {:ok, %Issue{comments: %Ecto.Association.NotLoaded{}}} = Issues.find_issue(scope, identifier)
  end

  test "a ticket in a project the person was not granted answers as one that does not exist", %{
    issue: %Issue{identifier: identifier}
  } do
    scope = user_scope(project_ids: [])

    assert {:error, :not_found} = Issues.find_issue(scope, identifier)
    assert {:error, :not_found} = Issues.find_issue(scope, "NOPE-1")
  end

  test "an identifier with no key, no number, or no such ticket is not found", %{local: local} do
    scope = user_scope(project_ids: [local.id])

    for identifier <- ["12", "#{local.key}-", "#{local.key}-abc", "garbage", "#{local.key}-999999"] do
      assert {:error, :not_found} = Issues.find_issue(scope, identifier)
    end
  end
end
