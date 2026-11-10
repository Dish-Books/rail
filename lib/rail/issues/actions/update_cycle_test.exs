defmodule Rail.Issues.Actions.UpdateCycleTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.Cycle

  setup do
    local = local_project()

    # Cycles 1 to 3 run Nov 10 to 23, Nov 24 to Dec 7 and Dec 8 to 21, with Cycle 1 running.
    :ok = Issues.close_cycle_day(~D[2026-11-10])
    stub(Date, :utc_today, fn -> ~D[2026-11-12] end)
    Phoenix.PubSub.subscribe(Rail.PubSub, "cycles")

    %{local: local, cycles: Repo.all(from(c in Cycle, where: c.project_id == ^local.id, order_by: c.number))}
  end

  test "moving a cycle's end later moves every later cycle as far, keeping their lengths", %{
    local: %{id: local_id} = local,
    cycles: [%{id: first_id} | _later]
  } do
    assert {:ok, %Cycle{id: ^first_id, starts_on: ~D[2026-11-10], ends_on: ~D[2026-11-26]}} =
             Issues.update_cycle(system_scope(), local, first_id, %{"ends_on" => "2026-11-26"})

    assert [
             {~D[2026-11-10], ~D[2026-11-26]},
             {~D[2026-11-27], ~D[2026-12-10]},
             {~D[2026-12-11], ~D[2026-12-24]}
           ] =
             Repo.all(
               from(c in Cycle, where: c.project_id == ^local_id, order_by: c.number, select: {c.starts_on, c.ends_on})
             )

    assert_receive {:cycles_changed, ^local_id}
  end

  test "moving a cycle's end earlier moves every later cycle earlier", %{
    local: %{id: local_id} = local,
    cycles: [%{id: first_id} | _later]
  } do
    assert {:ok, %Cycle{ends_on: ~D[2026-11-20]}} =
             Issues.update_cycle(system_scope(), local, first_id, %{"ends_on" => "2026-11-20"})

    assert [
             {~D[2026-11-10], ~D[2026-11-20]},
             {~D[2026-11-21], ~D[2026-12-04]},
             {~D[2026-12-05], ~D[2026-12-18]}
           ] =
             Repo.all(
               from(c in Cycle, where: c.project_id == ^local_id, order_by: c.number, select: {c.starts_on, c.ends_on})
             )
  end

  test "saving the same dates again changes nothing and tells nobody", %{
    local: %{id: local_id} = local,
    cycles: [_first, %{id: second_id} = second | _later]
  } do
    assert {:ok, %Cycle{id: ^second_id, starts_on: ~D[2026-11-24], ends_on: ~D[2026-12-07]}} =
             Issues.update_cycle(system_scope(), local, second_id, %{
               "starts_on" => Date.to_iso8601(second.starts_on),
               "ends_on" => Date.to_iso8601(second.ends_on)
             })

    refute_receive {:cycles_changed, ^local_id}
  end

  test "moving both dates of an upcoming cycle later shifts the next without an overlap", %{
    local: %{id: local_id} = local,
    cycles: [_first, %{id: second_id} | _later]
  } do
    assert {:ok, %Cycle{starts_on: ~D[2026-11-27], ends_on: ~D[2026-12-10]}} =
             Issues.update_cycle(system_scope(), local, second_id, %{
               "starts_on" => "2026-11-27",
               "ends_on" => "2026-12-10"
             })

    assert [_first, {~D[2026-11-27], ~D[2026-12-10]}, {~D[2026-12-11], ~D[2026-12-24]}] =
             Repo.all(
               from(c in Cycle, where: c.project_id == ^local_id, order_by: c.number, select: {c.starts_on, c.ends_on})
             )
  end

  test "a running cycle's start, an ended cycle and an overlapping start are refused, and no cycle moves", %{
    local: %{id: local_id} = local,
    cycles: [%{id: first_id}, %{id: second_id} | _later] = cycles
  } do
    dates = Enum.map(cycles, &{&1.starts_on, &1.ends_on})

    assert {:error, %Ecto.Changeset{} = running} =
             Issues.update_cycle(system_scope(), local, first_id, %{
               "starts_on" => "2026-11-11",
               "ends_on" => "2026-11-30"
             })

    assert %{starts_on: ["A running cycle keeps its start."]} = errors_on(running)

    assert {:error, %Ecto.Changeset{} = overlapping} =
             Issues.update_cycle(system_scope(), local, second_id, %{
               "starts_on" => "2026-11-20",
               "ends_on" => "2026-12-10"
             })

    assert %{starts_on: ["These dates overlap an earlier cycle."]} = errors_on(overlapping)

    stub(Date, :utc_today, fn -> ~D[2026-11-24] end)

    assert {:error, %Ecto.Changeset{} = ended} =
             Issues.update_cycle(system_scope(), local, first_id, %{"ends_on" => "2026-11-30"})

    assert %{ends_on: ["This cycle has ended, so its dates cannot change."]} = errors_on(ended)

    assert ^dates =
             Repo.all(
               from(c in Cycle, where: c.project_id == ^local_id, order_by: c.number, select: {c.starts_on, c.ends_on})
             )

    refute_receive {:cycles_changed, ^local_id}
  end

  test "a cycle of another project, or a project the scope cannot open, is not found", %{
    local: local,
    project: linear,
    cycles: [%{id: first_id} | _later]
  } do
    assert {:error, :not_found} = Issues.update_cycle(system_scope(), linear, first_id, %{"ends_on" => "2026-11-30"})

    assert {:error, :not_found} =
             Issues.update_cycle(temp_user_scope(project_ids: [linear.id]), local, first_id, %{"ends_on" => "2026-11-30"})
  end
end
