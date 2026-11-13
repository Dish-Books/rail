defmodule RailWeb.Mcp.Tools.ListIssuesTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.Cycle
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects
  alias Rail.Users

  setup do
    [local, hidden] =
      for name <- ["Listed", "Not granted"] do
        key = "MLS#{System.unique_integer([:positive])}"

        {:ok, project} =
          Projects.create_project(system_scope(), %{
            name: name,
            github_repo: "example/#{key}",
            github_installation_id: 1,
            tracker: :local,
            key: key,
            default_branch: "main",
            clone_path: "/tmp/#{key}"
          })

        project
      end

    id = System.unique_integer([:positive])

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "mli_#{id}",
        login: "mli_#{id}",
        name: "Mli",
        email: "mli_#{id}@example.com"
      })

    {:ok, user} = Users.update_user(system_scope(), user, %{project_ids: [local.id]})
    %{local: local, hidden: hidden, user: user, scope: Rail.Scope.for_user(user)}
  end

  test "without a project, lists only the projects the person can open", %{local: local, hidden: hidden, scope: scope} do
    {:ok, %Issue{identifier: shown}} = Issues.create_issue(system_scope(), local, %{title: "Shown"})
    {:ok, %Issue{identifier: kept_out}} = Issues.create_issue(system_scope(), hidden, %{title: "Kept out"})

    assert {:ok, %{"issues" => issues, "total" => 1}} = call_mcp_tool(scope, "list_issues", %{})
    assert [^shown] = Enum.map(issues, & &1["identifier"])
    refute kept_out in Enum.map(issues, & &1["identifier"])

    assert {:error, "No project you can open has that key or name. Yours are: " <> _keys} =
             call_mcp_tool(scope, "list_issues", %{"project" => hidden.key})
  end

  test "filters by state, assignee and text, leaves finished tickets out unless asked, and pages", %{
    local: local,
    user: %{login: login} = user,
    scope: scope
  } do
    {:ok, %Issue{identifier: mine}} =
      Issues.create_issue(system_scope(), local, %{title: "Mine to do", owner_user_id: user.id})

    {:ok, %Issue{identifier: other}} = Issues.create_issue(system_scope(), local, %{title: "Someone else's"})

    {:ok, %Issue{identifier: done_identifier} = done} =
      Issues.create_issue(system_scope(), local, %{title: "Finished one"})

    Repo.update_all(from(i in Issue, where: i.id == ^done.id), set: [state: :done])

    assert {:ok, %{"issues" => [%{"identifier" => ^mine, "assignee" => ^login}]}} =
             call_mcp_tool(scope, "list_issues", %{"project" => local.key, "assignee" => "me"})

    assert {:ok, %{"issues" => [%{"identifier" => ^mine}]}} =
             call_mcp_tool(scope, "list_issues", %{"assignee" => login})

    assert {:error, "assignee nobody-here is no one in Rail."} =
             call_mcp_tool(scope, "list_issues", %{"assignee" => "nobody-here"})

    assert {:ok, %{"issues" => [%{"identifier" => ^other}]}} =
             call_mcp_tool(scope, "list_issues", %{"query" => "someone"})

    assert {:ok, %{"issues" => [%{"identifier" => ^done_identifier}]}} =
             call_mcp_tool(scope, "list_issues", %{"state" => "done"})

    assert {:ok, %{"total" => 2}} = call_mcp_tool(scope, "list_issues", %{})

    assert {:ok, %{"total" => 3, "issues" => [_one]}} =
             call_mcp_tool(scope, "list_issues", %{"finished" => true, "limit" => 1})

    assert {:ok, %{"total" => 3, "issues" => [_two, _three]}} =
             call_mcp_tool(scope, "list_issues", %{"finished" => true, "offset" => 1})
  end

  test "filters by cycle in a Rail-tracked project, and refuses a cycle anywhere else", %{
    local: local,
    scope: scope,
    project: linear
  } do
    # Cycle 1 runs Nov 10 to 23, then Cycle 2.
    :ok = Issues.close_cycle_day(~D[2026-11-10])
    stub(Date, :utc_today, fn -> ~D[2026-11-12] end)

    [%Cycle{id: first_id}, %Cycle{id: second_id} | _later] =
      Repo.all(from(c in Cycle, where: c.project_id == ^local.id, order_by: c.number))

    {:ok, %Issue{identifier: now_identifier} = now} = Issues.create_issue(system_scope(), local, %{title: "This cycle"})

    {:ok, %Issue{identifier: later_identifier} = later} =
      Issues.create_issue(system_scope(), local, %{title: "Next cycle"})

    {:ok, _now} = Issues.set_issue_cycle(system_scope(), now, first_id)
    {:ok, _later} = Issues.set_issue_cycle(system_scope(), later, second_id)

    assert {:ok, %{"issues" => [%{"identifier" => ^now_identifier}]}} =
             call_mcp_tool(scope, "list_issues", %{"project" => local.key, "cycle" => "current"})

    assert {:ok, %{"issues" => [%{"identifier" => ^later_identifier}]}} =
             call_mcp_tool(scope, "list_issues", %{"project" => local.key, "cycle" => "next"})

    assert {:ok, %{"issues" => [%{"identifier" => ^now_identifier}]}} =
             call_mcp_tool(scope, "list_issues", %{"project" => local.key, "cycle" => "1"})

    for cycle <- ["99", "soon"] do
      assert {:error, "cycle is not current, next or a cycle number of " <> _key} =
               call_mcp_tool(scope, "list_issues", %{"project" => local.key, "cycle" => cycle})
    end

    assert {:error, "Only a Rail-tracked project's tickets can be listed by cycle" <> _rest} =
             call_mcp_tool(scope, "list_issues", %{"cycle" => "current"})

    assert {:error, "Only a Rail-tracked project's tickets can be listed by cycle" <> _rest} =
             call_mcp_tool(user_scope(project_ids: [linear.id]), "list_issues", %{"project" => linear.key, "cycle" => "1"})
  end
end
