defmodule RailWeb.Mcp.Tools.UpdateIssueTest do
  use Rail.DataCase, async: true

  alias Rail.Initiatives
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

  test "puts the ticket in an initiative of its project by name, and empty takes it out", %{
    local: local,
    issue: %Issue{id: id, identifier: identifier},
    scope: scope
  } do
    {:ok, %{id: initiative_id}} = Initiatives.create_initiative(system_scope(), local, %{name: "Credo exclusions"})

    assert {:ok, %{"issue" => %{"identifier" => ^identifier, "initiative" => "Credo exclusions"}}} =
             call_mcp_tool(scope, "update_issue", %{"identifier" => identifier, "initiative" => "Credo exclusions"})

    assert %Issue{initiative_id: ^initiative_id} = Repo.get!(Issue, id)

    assert {:ok, %{"issue" => %{"initiative" => nil}}} =
             call_mcp_tool(scope, "update_issue", %{"identifier" => identifier, "initiative" => ""})
  end

  test "an initiative not in the ticket's project is refused, names the project's, and writes nothing", %{
    local: local,
    issue: %Issue{id: id, identifier: identifier},
    scope: scope,
    github_project: other
  } do
    {:ok, _ours} = Initiatives.create_initiative(system_scope(), local, %{name: "Credo exclusions"})
    {:ok, _theirs} = Initiatives.create_initiative(system_scope(), other, %{name: "Elsewhere #{local.key}"})

    message = "initiative is not one in #{local.key}: Credo exclusions."

    assert {:error, ^message} =
             call_mcp_tool(scope, "update_issue", %{
               "identifier" => identifier,
               "title" => "Renamed",
               "initiative" => "Elsewhere #{local.key}"
             })

    assert %Issue{title: "Change me", initiative_id: nil} = Repo.get!(Issue, id)
  end

  test "a status sent with null fields moves the ticket, the nulls counted as left out", %{
    issue: %Issue{id: id, identifier: identifier},
    scope: scope
  } do
    assert {:ok, %{"issue" => %{"title" => "Change me", "status" => "Done"}}} =
             call_mcp_tool(scope, "update_issue", %{
               "identifier" => identifier,
               "status" => "Done",
               "title" => nil,
               "parent" => nil
             })

    assert %Issue{title: "Change me", state: :done} = Repo.get!(Issue, id)
  end

  test "a parent left null stays the ticket's parent", %{
    local: local,
    issue: %Issue{id: parent_id, identifier: parent_identifier} = parent,
    scope: scope
  } do
    {:ok, %Issue{id: id, identifier: identifier}} =
      Issues.create_issue(system_scope(), local, %{title: "A part", parent: parent})

    assert {:ok, %{"issue" => %{"status" => "In Progress", "parent" => %{"identifier" => ^parent_identifier}}}} =
             call_mcp_tool(scope, "update_issue", %{
               "identifier" => identifier,
               "status" => "In Progress",
               "parent" => nil
             })

    assert %Issue{parent_id: ^parent_id, state: :in_progress} = Repo.get!(Issue, id)
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
