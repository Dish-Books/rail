defmodule Rail.Issues.Actions.GetCyclesTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Projects

  setup do
    stub(Date, :utc_today, fn -> ~D[2026-10-29] end)

    cycle = fn id, number, starts_at, ends_at ->
      %{
        "id" => id,
        "number" => number,
        "name" => nil,
        "startsAt" => starts_at,
        "endsAt" => ends_at,
        "scopeHistory" => [10.0, 12.0],
        "inProgressScopeHistory" => [1.0, 2.0],
        "completedScopeHistory" => [0.0, 3.0]
      }
    end

    states = [
      %{"id" => "st_r", "name" => "In Review", "type" => "started", "position" => 3.0},
      %{"id" => "st_b", "name" => "Backlog", "type" => "backlog", "position" => 0.0}
    ]

    %{cycle: cycle, states: states}
  end

  test "the running cycle is current, numbered and dated as Linear shows it", %{
    project: project,
    cycle: cycle,
    states: states
  } do
    Req.Test.expect(Rail.Linear, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert %{"query" => query, "variables" => %{"teamId" => "lin_team_id", "since" => _since}} = Jason.decode!(body)
      assert query =~ "cyclesEnabled"
      assert query =~ "scopeHistory"

      Req.Test.json(conn, %{
        "data" => %{
          "team" => %{
            "cyclesEnabled" => true,
            "defaultIssueEstimate" => 1.6,
            "states" => %{"nodes" => states},
            "cycles" => %{
              "nodes" => [
                cycle.("cyc_13", 13.0, "2026-11-09T00:00:00.000Z", "2026-11-23T00:00:00.000Z"),
                cycle.("cyc_12", 12.0, "2026-10-26T00:00:00.000Z", "2026-11-09T00:00:00.000Z"),
                cycle.("cyc_11", 11.0, "2026-10-12T00:00:00.000Z", "2026-10-26T00:00:00.000Z")
              ]
            }
          }
        }
      })
    end)

    assert {:ok,
            %{
              cycles: [
                %{id: "cyc_11", number: 11, status: :ended, current: false},
                %{
                  id: "cyc_12",
                  number: 12,
                  name: nil,
                  starts_on: ~D[2026-10-26],
                  ends_on: ~D[2026-11-08],
                  status: :running,
                  current: true,
                  scope_history: [10.0, 12.0],
                  started_history: [1.0, 5.0],
                  completed_history: [+0.0, 3.0],
                  default_estimate: 2
                },
                %{id: "cyc_13", number: 13, status: :upcoming, current: false}
              ],
              statuses: [%{name: "Backlog", type: "backlog"}, %{name: "In Review", type: "started"}]
            }} = Issues.get_cycles(project)
  end

  test "between cycles the next one to start is current", %{project: project, cycle: cycle, states: states} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "team" => %{
            "cyclesEnabled" => true,
            "defaultIssueEstimate" => 1,
            "states" => %{"nodes" => states},
            "cycles" => %{
              "nodes" => [
                cycle.("cyc_14", 14, "2026-11-16T00:00:00.000Z", "2026-11-30T00:00:00.000Z"),
                cycle.("cyc_13", 13, "2026-11-02T00:00:00.000Z", "2026-11-16T00:00:00.000Z"),
                cycle.("cyc_11", 11, "2026-10-12T00:00:00.000Z", "2026-10-26T00:00:00.000Z")
              ]
            }
          }
        }
      })
    end)

    assert {:ok,
            %{
              cycles: [
                %{number: 11, current: false},
                %{number: 13, status: :upcoming, current: true},
                %{number: 14, status: :upcoming, current: false}
              ]
            }} = Issues.get_cycles(project)
  end

  test "a team with cycles off has none", %{project: project} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"team" => %{"cyclesEnabled" => false}}})
    end)

    assert {:ok, %{cycles: [], statuses: []}} = Issues.get_cycles(project)
  end

  test "a project with no Linear team, or on GitHub, has none and asks nobody", %{
    project: project,
    github_project: github_project
  } do
    assert {:ok, %{cycles: [], statuses: []}} = Issues.get_cycles(%{project | linear_team_id: nil})
    assert {:ok, %{cycles: [], statuses: []}} = Issues.get_cycles(github_project)
  end

  test "Linear failing is an error", %{project: project} do
    Req.Test.expect(Rail.Linear, fn conn -> conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{}) end)
    assert {:error, {:linear_api_error, 500, _body}} = Issues.get_cycles(project)
  end

  describe "a Rail-tracked project" do
    setup do
      local_key = "GCY#{System.unique_integer([:positive])}"

      {:ok, local} =
        Projects.create_project(system_scope(), %{
          name: "Cycles read",
          github_repo: "example/#{local_key}",
          github_installation_id: 1,
          tracker: :local,
          key: local_key,
          default_branch: "main",
          clone_path: "/tmp/#{local_key}"
        })

      %{local: local}
    end

    test "with no cycles yet has none, and Rail's eight statuses, each with its state", %{local: local} do
      assert {:ok,
              %{
                cycles: [],
                statuses: [
                  %{name: "Triage", type: "triage", position: 0, state: :triage},
                  %{name: "Backlog", type: "backlog", position: 1, state: :backlog},
                  %{name: "Todo", type: "unstarted", position: 2, state: :todo},
                  %{name: "In Progress", type: "started", position: 3, state: :in_progress},
                  %{name: "In Review", type: "started", position: 4, state: :in_review},
                  %{name: "Done", type: "completed", position: 5, state: :done},
                  %{name: "Canceled", type: "canceled", position: 6, state: :canceled},
                  %{name: "Duplicate", type: "canceled", position: 7, state: :duplicate}
                ]
              }} = Issues.get_cycles(local)
    end

    test "reads its cycles oldest first, the running one current, each day's figures in date order", %{local: local} do
      :ok = Issues.close_cycle_day(~D[2026-10-26])
      {:ok, issue} = Issues.create_issue(system_scope(), local, %{title: "Counted", estimate: 2})
      {:ok, %{cycles: [%{id: first_id} | _later]}} = Issues.get_cycles(local)
      {:ok, _issue} = Issues.set_issue_cycle(system_scope(), issue, first_id)
      :ok = Issues.close_cycle_day(~D[2026-10-28])
      {:ok, _done} = Issues.set_issue_status(system_scope(), issue, %{id: "done", name: "Done", state: :done})
      :ok = Issues.close_cycle_day(~D[2026-10-29])

      assert {:ok,
              %{
                cycles: [
                  %{
                    id: ^first_id,
                    number: 1,
                    name: nil,
                    starts_on: ~D[2026-10-26],
                    ends_on: ~D[2026-11-08],
                    status: :running,
                    current: true,
                    default_estimate: 1,
                    scope_history: [2, 2, 2],
                    started_history: [0, 0, 2],
                    completed_history: [0, 0, 2]
                  },
                  %{number: 2, status: :upcoming, current: false, scope_history: []},
                  %{number: 3, status: :upcoming, current: false}
                ]
              }} = Issues.get_cycles(local)
    end

    test "with none running, the next to start is current", %{local: local} do
      :ok = Issues.close_cycle_day(~D[2026-10-01])
      {:ok, %{cycles: [_first, %{id: second_id} | _later]}} = Issues.get_cycles(local)
      stub(Date, :utc_today, fn -> ~D[2026-10-02] end)
      {:ok, _cycle} = Issues.update_cycle(system_scope(), local, second_id, %{"starts_on" => "2026-10-20"})
      stub(Date, :utc_today, fn -> ~D[2026-10-16] end)

      assert {:ok,
              %{cycles: [%{status: :ended, current: false}, %{id: ^second_id, status: :upcoming, current: true}, _third]}} =
               Issues.get_cycles(local)
    end
  end
end
