defmodule RailWeb.Mcp.Tools.UpdateIssueTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects
  alias Rail.Scope
  alias Rail.Users

  setup do
    key = "MUI#{System.unique_integer([:positive])}"

    {:ok, local} =
      Projects.create_project(system_scope(), %{
        name: "Changed",
        github_repo: "example/#{key}",
        github_installation_id: 1,
        tracker: :local,
        key: key,
        default_branch: "main",
        clone_path: "/tmp/#{key}"
      })

    {:ok, user} =
      Users.register_oauth_user(%{github_id: "mui_#{key}", login: "mui_#{key}", name: "Mui", email: "#{key}@example.com"})

    {:ok, user} = Users.update_user(system_scope(), user, %{project_ids: [local.id]})

    {:ok, issue} =
      Issues.create_issue(system_scope(), local, %{title: "Change me", description: "Kept", priority: :low, estimate: 2})

    {:ok, blocker} = Issues.create_issue(system_scope(), local, %{title: "In the way"})
    %{local: local, user: user, issue: issue, blocker: blocker, scope: Scope.for_user(user)}
  end

  test "changes only the fields sent and answers with the ticket as it now reads", %{
    issue: %Issue{id: id, identifier: identifier},
    blocker: %Issue{identifier: blocker_identifier},
    user: %{id: user_id, login: login},
    scope: scope
  } do
    assert {:ok,
            %{
              "issue" => %{
                "identifier" => ^identifier,
                "title" => "Renamed",
                "description" => "Kept",
                "priority" => "low",
                "estimate" => 2,
                "status" => "In Progress",
                "assignee" => ^login,
                "blocked_by" => [%{"identifier" => ^blocker_identifier}]
              }
            }} =
             call_mcp_tool(scope, "update_issue", %{
               "identifier" => identifier,
               "title" => "Renamed",
               "status" => "in progress",
               "assignee" => "me",
               "blocked_by" => [blocker_identifier]
             })

    assert %Issue{title: "Renamed", description: "Kept", owner_user_id: ^user_id, state: :in_progress} =
             Repo.get!(Issue, id)
  end

  test "on a Linear ticket, a field Linear keeps is refused with a sentence and nothing changes", %{project: project} do
    {:ok, issue} =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project.id,
        external_id: "lin_mcp_update_1",
        identifier: "#{project.key}-7501",
        title: "Kept in Linear",
        state: :todo
      })
      |> Repo.insert()

    assert {:error, "A Linear ticket's estimate, title are edited in Linear, so nothing was changed." <> _rest} =
             call_mcp_tool(user_scope(project_ids: [project.id]), "update_issue", %{
               "identifier" => issue.identifier,
               "title" => "Renamed",
               "estimate" => 5,
               "status" => "Done"
             })

    assert %Issue{title: "Kept in Linear", state: :todo} = Repo.get!(Issue, issue.id)
  end

  test "an unknown ticket, or a field that does not resolve, changes nothing", %{
    issue: %Issue{id: id, identifier: identifier},
    scope: scope
  } do
    assert {:error, "No ticket NOPE-1 " <> _rest} = call_mcp_tool(scope, "update_issue", %{"identifier" => "NOPE-1"})

    assert {:error, "status is not one of: " <> _names} =
             call_mcp_tool(scope, "update_issue", %{"identifier" => identifier, "title" => "X", "status" => "Shipped"})

    assert %Issue{title: "Change me"} = Repo.get!(Issue, id)
  end
end
