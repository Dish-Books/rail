defmodule Rail.Issues.Actions.GetCyclesTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Projects

  setup do
    stub(Date, :utc_today, fn -> ~D[2026-10-29] end)

    local_key = "GCY#{System.unique_integer([:positive])}"

    {:ok, local} =
      Projects.create_project(system_scope(), %{
        name: "Cycles read",
        github_repo: "example/#{local_key}",
        github_installation_id: 1,
        key: local_key,
        default_branch: "main",
        clone_path: "/tmp/#{local_key}"
      })

    %{local: local}
  end

  test "a project with no cycles yet has none, and Rail's eight statuses, each with its state", %{local: local} do
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
