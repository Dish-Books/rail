defmodule Rail.Issues.Actions.SetIssueCycleTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.Cycle
  alias Rail.Issues.Schemas.Issue

  setup do
    [local, other] = [local_project(), local_project(%{name: "Elsewhere"})]

    # Each project's Cycle 1 runs Nov 10 to 23, then Cycle 2 from Nov 24.
    :ok = Issues.close_cycle_day(~D[2026-11-10])
    stub(Date, :utc_today, fn -> ~D[2026-11-12] end)
    {:ok, issue} = Issues.create_issue(system_scope(), local, %{title: "Plan me"})
    Phoenix.PubSub.subscribe(Rail.PubSub, "issues")

    cycles = fn project -> Repo.all(from(c in Cycle, where: c.project_id == ^project.id, order_by: c.number)) end
    %{local: local, issue: issue, cycles: cycles.(local), other_cycles: cycles.(other)}
  end

  test "puts the issue in an upcoming cycle and takes it out again, and a second pick sends nothing", %{
    issue: %{id: issue_id} = issue,
    cycles: [_first, %{id: second_id} | _later]
  } do
    assert {:ok, %Issue{id: ^issue_id, cycle_external_id: ^second_id}} =
             Issues.set_issue_cycle(system_scope(), issue, second_id)

    assert_receive {:issue_changed, ^issue_id}

    assert {:ok, %Issue{cycle_external_id: ^second_id}} = Issues.set_issue_cycle(system_scope(), issue, second_id)
    refute_receive {:issue_changed, ^issue_id}

    assert {:ok, %Issue{cycle_external_id: nil}} = Issues.set_issue_cycle(system_scope(), issue, nil)
    assert %Issue{cycle_external_id: nil} = Repo.get!(Issue, issue_id)
  end

  test "another project's cycle and an ended cycle are refused, and the issue keeps its cycle", %{
    issue: %{id: issue_id} = issue,
    cycles: [%{id: first_id}, %{id: second_id} | _later],
    other_cycles: [%{id: other_id} | _other_later]
  } do
    {:ok, _issue} = Issues.set_issue_cycle(system_scope(), issue, first_id)

    assert {:error, :not_found} = Issues.set_issue_cycle(system_scope(), issue, other_id)

    stub(Date, :utc_today, fn -> ~D[2026-11-24] end)
    {:ok, _issue} = Issues.set_issue_cycle(system_scope(), issue, second_id)
    assert {:error, :not_found} = Issues.set_issue_cycle(system_scope(), issue, first_id)

    assert %Issue{cycle_external_id: ^second_id} = Repo.get!(Issue, issue_id)
  end

  test "a Linear issue, or a scope that cannot open the project, is not found", %{
    project: linear,
    local: local,
    issue: issue,
    cycles: [%{id: first_id} | _later]
  } do
    linear_issue =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: linear.id,
        external_id: "lin_sic",
        identifier: "LIN-1",
        title: "Linear",
        state: :todo
      })
      |> Repo.insert!()

    assert {:error, :not_found} = Issues.set_issue_cycle(system_scope(), linear_issue, nil)

    assert {:error, :not_found} =
             Issues.set_issue_cycle(temp_user_scope(project_ids: [linear.id]), issue, first_id)

    assert {:ok, _issue} = Issues.set_issue_cycle(temp_user_scope(project_ids: [local.id]), issue, first_id)
  end
end
