defmodule Rail.Issues.Actions.CloseCycleDayTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.ClosedCycleIssue
  alias Rail.Issues.Schemas.Cycle
  alias Rail.Issues.Schemas.Issue

  setup do
    local = local_project()
    Phoenix.PubSub.subscribe(Rail.PubSub, "cycles")
    %{local: local}
  end

  test "the first run schedules Cycles 1 to 3 back to back, two weeks each from that day, and a second run adds none",
       %{local: %{id: local_id}, project: linear} do
    inactive = local_project(%{name: "Resting", active: false})

    assert :ok = Issues.close_cycle_day(~D[2026-11-10])
    assert :ok = Issues.close_cycle_day(~D[2026-11-10])

    assert [
             %Cycle{number: 1, starts_on: ~D[2026-11-10], ends_on: ~D[2026-11-23]},
             %Cycle{number: 2, starts_on: ~D[2026-11-24], ends_on: ~D[2026-12-07]},
             %Cycle{number: 3, starts_on: ~D[2026-12-08], ends_on: ~D[2026-12-21]}
           ] = Repo.all(from(c in Cycle, where: c.project_id == ^local_id, order_by: c.number))

    assert [] = Repo.all(from(c in Cycle, where: c.project_id in ^[inactive.id, linear.id]))
    assert_receive {:cycles_changed, ^local_id}
  end

  test "a day the run missed takes the points as they stood when it next ran, an unestimated issue counting 1", %{
    local: local
  } do
    :ok = Issues.close_cycle_day(~D[2026-11-10])
    {:ok, %{cycles: [%{id: cycle_id} | _later]}} = Issues.get_cycles(local)

    {:ok, estimated} = Issues.create_issue(system_scope(), local, %{title: "Estimated", estimate: 3})
    {:ok, unestimated} = Issues.create_issue(system_scope(), local, %{title: "Unestimated"})
    {:ok, _issue} = Issues.set_issue_cycle(system_scope(), estimated, cycle_id)
    {:ok, _issue} = Issues.set_issue_cycle(system_scope(), unestimated, cycle_id)

    # Day 5's run records days 1 to 4; day 6's never runs, so day 7's records days 5 and 6 as they stand then.
    :ok = Issues.close_cycle_day(~D[2026-11-14])
    {:ok, _done} = Issues.set_issue_status(system_scope(), estimated, %{id: "done", name: "Done", state: :done})
    :ok = Issues.close_cycle_day(~D[2026-11-16])

    assert {:ok,
            %{
              cycles: [
                %{
                  id: ^cycle_id,
                  scope_history: [4, 4, 4, 4, 4, 4],
                  started_history: [0, 0, 0, 0, 3, 3],
                  completed_history: [0, 0, 0, 0, 3, 3]
                }
                | _later
              ]
            }} = Issues.get_cycles(local)
  end

  test "the run after a cycle's last day closes it with every issue's state and rolls the unfinished ones over", %{
    local: %{id: local_id} = local
  } do
    :ok = Issues.close_cycle_day(~D[2026-11-10])

    [%Cycle{id: first_id}, %Cycle{id: second_id} | _later] =
      Repo.all(from(c in Cycle, where: c.project_id == ^local_id, order_by: c.number))

    held =
      for state <- Issue.states(), into: %{} do
        {:ok, issue} = Issues.create_issue(system_scope(), local, %{title: "#{state}"})
        {:ok, issue} = Issues.set_issue_cycle(system_scope(), issue, first_id)
        status = %{id: "#{state}", name: Issue.state_label(state), state: state}
        {:ok, issue} = if state == :triage, do: {:ok, issue}, else: Issues.set_issue_status(system_scope(), issue, status)
        {state, issue.id}
      end

    :ok = Issues.close_cycle_day(~D[2026-11-24])
    :ok = Issues.close_cycle_day(~D[2026-11-24])

    closed = Repo.all(from(c in ClosedCycleIssue, where: c.cycle_id == ^first_id, select: {c.issue_id, c.state}))
    assert Map.new(closed) == Map.new(held, fn {state, id} -> {id, state} end)

    cycles = Map.new(Repo.all(from(i in Issue, where: i.id in ^Map.values(held), select: {i.id, i.cycle_external_id})))

    for {state, id} <- held do
      assert cycles[id] == if(Issue.finished_state?(state), do: first_id, else: second_id)
    end

    assert [1, 2, 3, 4] =
             Repo.all(from(c in Cycle, where: c.project_id == ^local_id, order_by: c.number, select: c.number))
  end

  test "with the run after a cycle's last day missed, the next run still records that day and closes it", %{
    local: %{id: local_id} = local
  } do
    :ok = Issues.close_cycle_day(~D[2026-11-10])

    [%Cycle{id: first_id}, %Cycle{id: second_id} | _later] =
      Repo.all(from(c in Cycle, where: c.project_id == ^local_id, order_by: c.number))

    {:ok, issue} = Issues.create_issue(system_scope(), local, %{title: "Rolls over"})
    {:ok, %{id: issue_id}} = Issues.set_issue_cycle(system_scope(), issue, first_id)

    :ok = Issues.close_cycle_day(~D[2026-11-25])

    assert {:ok, %{cycles: [%{id: ^first_id, scope_history: scope} | _later]}} = Issues.get_cycles(local)
    assert length(scope) == 14

    assert [%ClosedCycleIssue{issue_id: ^issue_id, state: :triage}] =
             Repo.all(from(c in ClosedCycleIssue, where: c.cycle_id == ^first_id))

    assert %Issue{cycle_external_id: ^second_id} = Repo.get!(Issue, issue_id)
  end

  test "a project made active again starts a cycle that day for the issues its ended cycles leave", %{
    local: %{id: local_id} = local
  } do
    :ok = Issues.close_cycle_day(~D[2026-11-10])
    [%Cycle{id: first_id} | _later] = Repo.all(from(c in Cycle, where: c.project_id == ^local_id, order_by: c.number))
    {:ok, issue} = Issues.create_issue(system_scope(), local, %{title: "Waits"})
    {:ok, %{id: issue_id}} = Issues.set_issue_cycle(system_scope(), issue, first_id)

    :ok = Issues.close_cycle_day(~D[2027-02-01])

    assert %Issue{cycle_external_id: cycle_id} = Repo.get!(Issue, issue_id)
    assert %Cycle{number: 4, starts_on: ~D[2027-02-01], ends_on: ~D[2027-02-14]} = Repo.get!(Cycle, cycle_id)

    assert [1, 2, 3, 4, 5, 6] =
             Repo.all(from(c in Cycle, where: c.project_id == ^local_id, order_by: c.number, select: c.number))
  end
end
