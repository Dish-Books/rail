defmodule Rail.Issues.Actions.ChangeIssueTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Issues
  alias Rail.Issues.Schemas.Cycle
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Schemas.IssueRelation
  alias Rail.Issues.Workers.SyncIssue
  alias Rail.Projects
  alias Rail.Users

  setup do
    key = "Chg#{System.unique_integer([:positive])}"

    {:ok, local} =
      Projects.create_project(system_scope(), %{
        name: "Changed here",
        github_repo: "example/#{key}",
        github_installation_id: 1,
        tracker: :local,
        key: key,
        default_branch: "main",
        clone_path: "/tmp/#{key}"
      })

    {:ok, teammate} =
      Users.register_oauth_user(%{github_id: "gh_#{key}", login: "Mate_#{key}", email: "#{key}@example.com"})

    teammate = teammate |> Ecto.Changeset.change(project_ids: [local.id]) |> Repo.update!()

    # Cycle 1 runs Nov 10 to 23, and the cycles after it follow.
    :ok = Issues.close_cycle_day(~D[2026-11-10])
    stub(Date, :utc_today, fn -> ~D[2026-11-12] end)

    {:ok, issue} = Issues.create_issue(system_scope(), local, %{title: "Change me"})
    {:ok, other} = Issues.create_issue(system_scope(), local, %{title: "Another"})
    cycles = Repo.all(from(c in Cycle, where: c.project_id == ^local.id, order_by: c.number))

    %{
      local: local,
      teammate: teammate,
      issue: issue,
      other: other,
      cycles: cycles,
      scope: Rail.Scope.for_user(teammate)
    }
  end

  describe "on a Linear ticket" do
    setup %{project: project} do
      issue =
        %Issue{}
        |> Issue.tracker_changeset(%{
          project_id: project.id,
          external_id: "lin_change_1",
          identifier: "TST-7101",
          title: "Kept in Linear",
          state: :todo,
          state_name: "Todo"
        })
        |> Repo.insert!()

      %{linear_issue: issue}
    end

    test "a title with a status changes neither, saying the title is edited in Linear", %{
      linear_issue: %Issue{id: id} = issue
    } do
      assert {:error, {:edited_in_tracker, :linear, [:title]}} =
               Issues.change_issue(system_scope(), issue, %{title: "Renamed", status: "Done"})

      assert %Issue{title: "Kept in Linear", state: :todo} = Repo.get!(Issue, id)
    end

    test "a status alone moves the ticket in Linear", %{linear_issue: %Issue{id: id} = issue} do
      Req.Test.expect(Rail.Linear, fn conn ->
        Req.Test.json(conn, %{
          "data" => %{
            "teams" => %{
              "nodes" => [
                %{
                  "states" => %{
                    "nodes" => [
                      %{"id" => "st_todo", "name" => "Todo", "type" => "unstarted", "position" => 1.0},
                      %{"id" => "st_done", "name" => "Done", "type" => "completed", "position" => 5.0}
                    ]
                  }
                }
              ]
            }
          }
        })
      end)

      Req.Test.expect(Rail.Linear, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert %{"id" => "lin_change_1", "input" => %{"stateId" => "st_done"}} = Jason.decode!(body)["variables"]

        Req.Test.json(conn, %{
          "data" => %{
            "issueUpdate" => %{
              "success" => true,
              "issue" => %{
                "id" => "lin_change_1",
                "identifier" => "TST-7101",
                "title" => "Kept in Linear",
                "state" => %{"name" => "Done", "type" => "completed"},
                "completedAt" => "2026-11-12T10:00:00.000Z",
                "updatedAt" => "2026-11-12T10:00:00.000Z"
              }
            }
          }
        })
      end)

      assert {:ok, %Issue{id: ^id, state: :done, state_name: "Done"}} =
               Issues.change_issue(system_scope(), issue, %{status: " done "})
    end
  end

  test "an unknown status with a good title writes nothing", %{issue: %Issue{id: id} = issue, scope: scope} do
    assert {:error, {:invalid, :status, "is not one of: " <> names}} =
             Issues.change_issue(scope, issue, %{title: "Renamed", status: "Shipped"})

    assert names =~ "In Progress"
    assert %Issue{title: "Change me"} = Repo.get!(Issue, id)
  end

  test "sets the text, priority, estimate, parent, status, cycle, assignee and blockers, and open pages hear it", %{
    issue: %Issue{id: id} = issue,
    other: %Issue{id: other_id, identifier: other_identifier, external_id: other_external_id},
    teammate: %{id: teammate_id, login: login},
    cycles: [%{id: first_id}, %{id: second_id} | _later],
    scope: scope
  } do
    assert {:ok,
            %Issue{
              id: ^id,
              title: "Renamed",
              description: "Why",
              priority: :high,
              estimate: 3,
              parent_external_id: ^other_external_id,
              state: :in_progress,
              cycle_external_id: ^second_id,
              owner_user_id: ^teammate_id
            }} =
             Issues.change_issue(scope, issue, %{
               title: "Renamed",
               description: "Why",
               priority: "high",
               estimate: 3,
               parent: String.downcase(other_identifier),
               status: "in progress",
               cycle: "next",
               assignee: String.upcase(login),
               blocked_by: [other_identifier]
             })

    assert [%IssueRelation{blocker_issue_id: ^other_id}] =
             Repo.all(from(r in IssueRelation, where: r.blocked_issue_id == ^id))

    # The assignee reaches open pages once the tracker has it, as the issue page's own assign does.
    [job] = all_enqueued(worker: SyncIssue, args: %{issue_id: id})
    Phoenix.PubSub.subscribe(Rail.PubSub, "issues")
    assert :ok = perform_job(SyncIssue, job.args)
    assert_receive {:issue_changed, ^id}

    assert {:ok, %Issue{cycle_external_id: ^first_id, owner_user_id: nil, parent_external_id: nil}} =
             Issues.change_issue(scope, issue, %{cycle: "current", assignee: "", parent: ""})

    assert {:ok, %Issue{cycle_external_id: ^second_id, owner_user_id: ^teammate_id}} =
             Issues.change_issue(scope, issue, %{cycle: 2, assignee: "me"})

    assert {:ok, %Issue{cycle_external_id: nil}} = Issues.change_issue(scope, issue, %{cycle: "None", blocked_by: []})
    assert [] = Repo.all(from(r in IssueRelation, where: r.blocked_issue_id == ^id))
  end

  test "each field that does not resolve is refused before anything is written", %{
    issue: %Issue{id: id, identifier: identifier} = issue,
    other: other,
    scope: scope
  } do
    :ok = Issues.block_issue(scope, issue, other)

    for {attrs, field} <- [
          {%{status: 3}, :status},
          {%{cycle: "later"}, :cycle},
          {%{cycle: 1_000}, :cycle},
          {%{assignee: "nobody_here"}, :assignee},
          {%{assignee: 7}, :assignee},
          {%{parent: identifier}, :parent},
          {%{parent: "TST-1"}, :parent},
          {%{blocked_by: ["#{identifier |> String.split("-") |> hd()}-999999"]}, :blocked_by},
          {%{blocked_by: [other.identifier]}, :blocked_by},
          {%{blocked_by: [42]}, :blocked_by},
          {%{blocked_by: "#{other.identifier}"}, :blocked_by}
        ] do
      assert {:error, {:invalid, ^field, message}} =
               Issues.change_issue(scope, %{issue | title: "stale"}, Map.put(attrs, :title, "Renamed"))

      assert byte_size(message) > 0
    end

    assert {:error, %Ecto.Changeset{}} = Issues.change_issue(scope, issue, %{title: " ", priority: "soon"})
    assert %Issue{title: "Change me"} = Repo.get!(Issue, id)
    assert {:ok, %Issue{title: "Change me"}} = Issues.change_issue(scope, issue, %{})
  end

  test "a write that fails after others says which were saved, and a first failure is its own error", %{
    issue: %Issue{id: id, identifier: identifier} = issue,
    scope: scope
  } do
    assert {:error, {:partly_saved, [:title, :priority], [:blocked_by], %Ecto.Changeset{}}} =
             Issues.change_issue(scope, issue, %{title: "Renamed", priority: "low", blocked_by: [identifier]})

    assert %Issue{title: "Renamed", priority: :low} = Repo.get!(Issue, id)
    assert {:error, %Ecto.Changeset{}} = Issues.change_issue(scope, issue, %{blocked_by: [identifier]})
  end

  test "a project with no cycles has no current or next one, nor one after its last", %{scope: scope, teammate: teammate} do
    key = "Chn#{System.unique_integer([:positive])}"

    {:ok, bare} =
      Projects.create_project(system_scope(), %{
        name: "No cycles",
        github_repo: "example/#{key}",
        github_installation_id: 1,
        tracker: :local,
        key: key,
        default_branch: "main",
        clone_path: "/tmp/#{key}"
      })

    Repo.delete_all(from(c in Cycle, where: c.project_id == ^bare.id))
    {:ok, issue} = Issues.create_issue(system_scope(), bare, %{title: "Unplanned"})
    scope = %{scope | user: %{teammate | admin: true}}

    assert {:error, {:invalid, :cycle, _message}} = Issues.change_issue(scope, issue, %{cycle: "current"})
    assert {:error, {:invalid, :cycle, _message}} = Issues.change_issue(scope, issue, %{cycle: "next"})

    %Cycle{project_id: bare.id}
    |> Cycle.changeset(%{starts_on: ~D[2026-11-10], ends_on: ~D[2026-11-23]})
    |> Repo.insert!()

    assert {:error, {:invalid, :cycle, _message}} = Issues.change_issue(scope, issue, %{cycle: "next"})
  end

  test "a ticket the person cannot open, or one read under the wrong project, is not found", %{
    issue: issue,
    project: linear
  } do
    assert {:error, :not_found} = Issues.change_issue(user_scope(project_ids: []), issue, %{title: "Renamed"})

    assert {:error, :not_found} =
             Issues.change_issue(system_scope(), %{issue | project_id: linear.id}, %{title: "Renamed"})

    assert {:error, :not_found} = Issues.change_issue(system_scope(), %{issue | id: "iss_missing"}, %{title: "Renamed"})
  end
end
