defmodule RailWeb.Mcp.Tools.CreateIssueTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.Cycle
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects
  alias Rail.Scope
  alias Rail.Users

  setup {Req.Test, :verify_on_exit!}

  setup do
    key = "MCI#{System.unique_integer([:positive])}"

    {:ok, local} =
      Projects.create_project(system_scope(), %{
        name: "Filed into",
        github_repo: "example/#{key}",
        github_installation_id: 1,
        tracker: :local,
        key: key,
        default_branch: "main",
        clone_path: "/tmp/#{key}"
      })

    {:ok, user} =
      Users.register_oauth_user(%{github_id: "mci_#{key}", login: "mci_#{key}", name: "Mci", email: "#{key}@example.com"})

    {:ok, teammate} =
      Users.register_oauth_user(%{
        github_id: "mct_#{key}",
        login: "Mate_#{key}",
        name: "Mate",
        email: "t#{key}@example.com"
      })

    {:ok, user} = Users.update_user(system_scope(), user, %{project_ids: [local.id]})
    {:ok, teammate} = Users.update_user(system_scope(), teammate, %{project_ids: [local.id]})
    Phoenix.PubSub.subscribe(Rail.PubSub, "issues")
    %{local: local, user: user, teammate: teammate, scope: Scope.for_user(user)}
  end

  test "a parent files a sub-issue owned by the person, and open pages hear of it", %{
    local: local,
    user: %{id: user_id, login: login},
    scope: scope
  } do
    {:ok, %Issue{identifier: parent_identifier}} = Issues.create_issue(system_scope(), local, %{title: "Parent"})
    assert_receive {:issue_created, _parent_id}

    assert {:ok,
            %{
              "issue" => %{
                "identifier" => identifier,
                "title" => "Split out",
                "description" => "The rest of it",
                "priority" => "high",
                "estimate" => 3,
                "status" => "Todo",
                "assignee" => ^login,
                "parent" => %{"identifier" => ^parent_identifier}
              }
            }} =
             call_mcp_tool(scope, "create_issue", %{
               "project" => local.key,
               "title" => "Split out",
               "description" => "The rest of it",
               "priority" => "high",
               "estimate" => 3,
               "parent" => parent_identifier
             })

    assert {:ok, %Issue{id: id, owner_user_id: ^user_id}} = Issues.get_issue(identifier)
    assert_receive {:issue_created, ^id}
  end

  test "files a ticket into the current or next cycle, or one by number, and refuses an ended one", %{
    local: %{id: local_id} = local,
    scope: scope
  } do
    # Cycle 1 runs Nov 10 to 23, then Cycle 2 from Nov 24.
    :ok = Issues.close_cycle_day(~D[2026-11-10])
    stub(Date, :utc_today, fn -> ~D[2026-11-12] end)

    [%{id: first_id}, %{id: second_id} | _later] =
      Repo.all(from(c in Cycle, where: c.project_id == ^local_id, order_by: c.number))

    assert {:ok, %{"issue" => %{"identifier" => current, "cycle" => %{"number" => 1, "current" => true}}}} =
             call_mcp_tool(scope, "create_issue", %{"project" => local.key, "title" => "Now", "cycle" => "Current"})

    assert {:ok, %Issue{cycle_external_id: ^first_id}} = Issues.get_issue(current)

    assert {:ok, %{"issue" => %{"identifier" => next, "cycle" => %{"number" => 2, "current" => false}}}} =
             call_mcp_tool(scope, "create_issue", %{"project" => local.key, "title" => "Later", "cycle" => "next"})

    assert {:ok, %Issue{cycle_external_id: ^second_id}} = Issues.get_issue(next)

    assert {:ok, %{"issue" => %{"cycle" => %{"number" => 2}}}} =
             call_mcp_tool(scope, "create_issue", %{"project" => local.key, "title" => "By number", "cycle" => "2"})

    assert {:ok, %{"issue" => %{"cycle" => nil}}} =
             call_mcp_tool(scope, "create_issue", %{"project" => local.key, "title" => "Unplanned"})

    stub(Date, :utc_today, fn -> ~D[2026-11-24] end)
    count = Repo.aggregate(from(i in Issue, where: i.project_id == ^local_id), :count)

    assert {:error, "cycle is not current, next, none or an open cycle's number: 2" <> _later} =
             call_mcp_tool(scope, "create_issue", %{"project" => local.key, "title" => "Too late", "cycle" => "1"})

    assert Repo.aggregate(from(i in Issue, where: i.project_id == ^local_id), :count) == count
  end

  test "a cycle on a GitHub ticket is refused, since GitHub keeps its own", %{github_project: github} do
    assert {:error, "A GitHub project's cycles are kept in GitHub; open them there."} =
             call_mcp_tool(user_scope(project_ids: [github.id]), "create_issue", %{
               "project" => github.key,
               "title" => "Planned",
               "cycle" => "current"
             })
  end

  test "names another assignee, or none", %{
    local: local,
    teammate: %{id: teammate_id, login: teammate_login},
    scope: scope
  } do
    assert {:ok, %{"issue" => %{"identifier" => theirs}}} =
             call_mcp_tool(scope, "create_issue", %{
               "project" => local.key,
               "title" => "For a teammate",
               "assignee" => String.downcase(teammate_login)
             })

    assert {:ok, %Issue{owner_user_id: ^teammate_id}} = Issues.get_issue(theirs)

    assert {:ok, %{"issue" => %{"assignee" => nil, "description" => ""}}} =
             call_mcp_tool(scope, "create_issue", %{"project" => local.key, "title" => "Nobody's", "assignee" => " "})

    assert {:error, "assignee stranger can't be assigned a ticket in " <> _key} =
             call_mcp_tool(scope, "create_issue", %{"project" => local.key, "title" => "X", "assignee" => "stranger"})
  end

  test "a null assignee files the ticket assigned to the person", %{
    local: local,
    user: %{id: user_id, login: login},
    scope: scope
  } do
    assert {:ok, %{"issue" => %{"identifier" => identifier, "assignee" => ^login}}} =
             call_mcp_tool(scope, "create_issue", %{"project" => local.key, "title" => "Mine", "assignee" => nil})

    assert {:ok, %Issue{owner_user_id: ^user_id}} = Issues.get_issue(identifier)
  end

  test "an estimate below 0 is refused and files nothing", %{local: %{id: local_id} = local, scope: scope} do
    assert {:error, "estimate must be greater than or equal to 0."} =
             call_mcp_tool(scope, "create_issue", %{"project" => local.key, "title" => "Negative", "estimate" => -5})

    refute Repo.exists?(from(i in Issue, where: i.project_id == ^local_id))
  end

  test "files a Linear ticket unassigned, and says so, when Linear cannot assign the person", %{
    project: linear,
    user: user
  } do
    {:ok, user} = Users.update_user(system_scope(), user, %{project_ids: [linear.id]})
    identifier = "#{linear.key}-7401"

    Req.Test.expect(Rail.Linear, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      refute Map.has_key?(Jason.decode!(body)["variables"]["input"], "assigneeId")

      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_mcp_create_1", "identifier" => identifier, "title" => "Filed"}
          }
        }
      })
    end)

    assert {:ok,
            %{"issue" => %{"identifier" => ^identifier, "assignee" => nil, "note" => "Filed unassigned: Linear" <> _rest}}} =
             call_mcp_tool(Scope.for_user(user), "create_issue", %{"project" => linear.key, "title" => "Filed"})
  end

  test "refuses a project the person cannot open, a parent elsewhere, and a parent on GitHub", %{
    local: local,
    scope: scope,
    github_project: github
  } do
    assert {:error, "No project you can open has that key or name. Yours are: " <> _keys} =
             call_mcp_tool(scope, "create_issue", %{"project" => github.key, "title" => "Elsewhere"})

    assert {:error, "parent NOPE-1 is not a ticket in this project."} =
             call_mcp_tool(scope, "create_issue", %{"project" => local.key, "title" => "Orphan", "parent" => "NOPE-1"})

    github_scope = user_scope(project_ids: [github.id])

    assert {:error, "GitHub keeps no parent" <> _rest} =
             call_mcp_tool(github_scope, "create_issue", %{"project" => github.key, "title" => "Sub", "parent" => "x#1"})

    assert {:error, "title can't be blank."} =
             call_mcp_tool(scope, "create_issue", %{"project" => local.key, "title" => ""})
  end
end
