defmodule RailWeb.Mcp.Tools.GetIssueTest do
  use Rail.DataCase, async: true

  alias Rail.Initiatives
  alias Rail.Issues
  alias Rail.Issues.Schemas.Cycle
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects
  alias Rail.Scope
  alias Rail.Users

  setup do
    key = "MGI#{System.unique_integer([:positive])}"

    {:ok, local} =
      Projects.create_project(system_scope(), %{
        name: "Opened",
        github_repo: "example/#{key}",
        github_installation_id: 1,
        key: key,
        default_branch: "main",
        clone_path: "/tmp/#{key}"
      })

    {:ok, user} =
      Users.register_oauth_user(%{github_id: "mgi_#{key}", login: "mgi_#{key}", name: "Mgi", email: "#{key}@example.com"})

    {:ok, user} = Users.update_user(system_scope(), user, %{project_ids: [local.id]})
    %{local: local, user: user, scope: Scope.for_user(user)}
  end

  test "a ticket carries its assignee, cycle, parent, sub-issues, blockers and comments", %{
    local: local,
    user: %{login: login} = user,
    scope: scope
  } do
    :ok = Issues.close_cycle_day(~D[2026-11-10])
    stub(Date, :utc_today, fn -> ~D[2026-11-12] end)
    [%Cycle{id: cycle_id} | _later] = Repo.all(from(c in Cycle, where: c.project_id == ^local.id, order_by: c.number))

    {:ok, %Issue{identifier: parent_identifier} = parent} =
      Issues.create_issue(system_scope(), local, %{title: "The parent"})

    {:ok, issue} =
      Issues.create_issue(system_scope(), local, %{
        title: "Opened in full",
        description: "All of it",
        owner_user_id: user.id,
        parent: parent
      })

    {:ok, %Issue{identifier: child_identifier}} =
      Issues.create_issue(system_scope(), local, %{title: "Child", parent: issue})

    {:ok, %Issue{identifier: blocker_identifier} = blocker} =
      Issues.create_issue(system_scope(), local, %{title: "Blocker"})

    {:ok, _issue} = Issues.set_issue_cycle(system_scope(), issue, cycle_id)
    {:ok, initiative} = Initiatives.create_initiative(system_scope(), local, %{name: "Credo exclusions"})
    {:ok, _issue} = Issues.set_issue_initiative(system_scope(), issue, initiative.id)
    :ok = Issues.block_issue(system_scope(), blocker, issue)
    {:ok, _comment} = Issues.comment(scope, issue, %{body: "First thoughts"})

    assert {:ok,
            %{
              "issue" => %{
                "title" => "Opened in full",
                "description" => "All of it",
                "assignee" => ^login,
                "cycle" => %{"number" => 1, "starts_on" => "2026-11-10"},
                "initiative" => "Credo exclusions",
                "parent" => %{"identifier" => ^parent_identifier, "title" => "The parent"},
                "sub_issues" => [%{"identifier" => ^child_identifier}],
                "blocked_by" => [%{"identifier" => ^blocker_identifier}],
                "blocks" => [],
                "comments" => [%{"author" => ^login, "body" => "First thoughts", "replies" => []}]
              }
            }} = call_mcp_tool(scope, "get_issue", %{"identifier" => String.downcase(issue.identifier)})
  end

  test "a comment Rail posted itself is signed with Rail's name", %{local: local, scope: scope} do
    {:ok, issue} = Issues.create_issue(system_scope(), local, %{title: "Commented by Rail"})
    {:ok, _comment} = Issues.comment(system_scope(), issue, %{body: "Demo recorded."})

    assert {:ok, %{"issue" => %{"comments" => [%{"author" => "Rail", "body" => "Demo recorded."}]}}} =
             call_mcp_tool(scope, "get_issue", %{"identifier" => issue.identifier})
  end

  test "a ticket in a project the person cannot open answers as one that does not exist", %{local: local} do
    {:ok, issue} = Issues.create_issue(system_scope(), local, %{title: "Hidden"})

    assert {:error, "No ticket " <> _rest} =
             call_mcp_tool(user_scope(project_ids: []), "get_issue", %{"identifier" => issue.identifier})
  end
end
