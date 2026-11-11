defmodule Rail.Issues.Actions.CloseCycleDay do
  @moduledoc """
  The nightly run over every active Rail-tracked project's cycles, and the one place they are created.
  """

  import Ecto.Query
  import Rail.Issues.Utils.LockCycles
  import Rail.Issues.Utils.SumCyclePoints

  alias Rail.Issues.Schemas.ClosedCycleIssue
  alias Rail.Issues.Schemas.Cycle
  alias Rail.Issues.Schemas.CycleDay
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  @first_length 14
  @ahead 2

  @doc """
  For each active Rail-tracked project, in a transaction of its own: records every finished day not yet recorded, keeps
  two cycles scheduled after the current one, and closes each cycle whose last day it just recorded, rolling its
  unfinished issues over. Each project's pages hear `{:cycles_changed, project_id}` on `"cycles"` once it commits.
  """
  def close_cycle_day(%Date{} = today) do
    project_ids = Repo.all(from(p in Project, where: p.active and p.tracker == :local, select: p.id))

    for project_id <- project_ids do
      {:ok, _closed} = Repo.transaction(fn -> run_day(project_id, today) end)
      Phoenix.PubSub.broadcast(Rail.PubSub, "cycles", {:cycles_changed, project_id})
    end

    :ok
  end

  defp run_day(project_id, today) do
    cycles = lock_cycles(project_id)
    closing = record_days(project_id, cycles, Date.add(today, -1))
    cycles = schedule_ahead(project_id, cycles, today)
    Enum.each(closing, &close_cycle(project_id, &1, cycles, today))
  end

  # A missed day takes the figures as they stand now, the only ones Rail still has. Returns the cycles it recorded the
  # last day of.
  defp record_days(project_id, cycles, yesterday) do
    started = Enum.filter(cycles, &(Date.compare(&1.starts_on, yesterday) != :gt))
    ids = Enum.map(started, & &1.id)

    recorded =
      from(d in CycleDay, where: d.cycle_id in ^ids, group_by: d.cycle_id, select: {d.cycle_id, max(d.day)})
      |> Repo.all()
      |> Map.new()

    Enum.flat_map(started, fn cycle ->
      first = if recorded[cycle.id], do: Date.add(recorded[cycle.id], 1), else: cycle.starts_on
      last = Enum.min([yesterday, cycle.ends_on], Date)

      if Date.after?(first, last) do
        []
      else
        record_cycle_days(project_id, cycle, Date.range(first, last))
        if last == cycle.ends_on, do: [cycle], else: []
      end
    end)
  end

  defp record_cycle_days(project_id, cycle, days) do
    rows = sum_cycle_points(project_id, cycle.id, Cycle.default_estimate())
    [scope, started, completed] = for field <- 1..3, do: rows |> Enum.map(&elem(&1, field)) |> Enum.sum()

    days =
      for day <- days,
          do: %{
            id: UXID.generate!(prefix: "cyd"),
            cycle_id: cycle.id,
            day: day,
            scope: scope,
            started: started,
            completed: completed
          }

    Repo.insert_all(CycleDay, days, on_conflict: :nothing, conflict_target: [:cycle_id, :day])
  end

  # The current cycle is the first that has not ended: the running one, or else the next to start.
  defp schedule_ahead(project_id, cycles, today) do
    current = Enum.find(cycles, &(Cycle.calculate_status(&1, today) != :ended))
    ahead = current && Enum.count(cycles, &Date.after?(&1.starts_on, current.ends_on))

    if is_integer(ahead) and ahead >= @ahead,
      do: cycles,
      else:
        schedule_ahead(project_id, List.insert_at(cycles, -1, insert_next(project_id, List.last(cycles), today)), today)
  end

  defp insert_next(project_id, nil, today), do: insert_cycle(project_id, today, Date.add(today, @first_length - 1))

  # Each copies the length of the latest, so editing the last cycle sets the length of those after it.
  defp insert_next(project_id, %Cycle{} = latest, today) do
    starts_on = Enum.max([Date.add(latest.ends_on, 1), today], Date)
    insert_cycle(project_id, starts_on, Date.add(starts_on, Date.diff(latest.ends_on, latest.starts_on)))
  end

  defp insert_cycle(project_id, starts_on, ends_on) do
    %Cycle{project_id: project_id}
    |> Cycle.changeset(%{starts_on: starts_on, ends_on: ends_on})
    |> Repo.insert!()
  end

  # The issues are locked as they are read, so a status change at this moment waits and the closing row agrees with
  # where the issue goes.
  defp close_cycle(project_id, %Cycle{id: cycle_id}, cycles, today) do
    held =
      Repo.all(
        from(i in Issue,
          where: i.project_id == ^project_id and i.cycle_external_id == ^cycle_id,
          lock: "FOR UPDATE",
          select: {i.id, i.state}
        )
      )

    now = DateTime.utc_now()

    rows =
      for {issue_id, state} <- held,
          do: %{
            id: UXID.generate!(prefix: "ccl"),
            project_id: project_id,
            cycle_id: cycle_id,
            issue_id: issue_id,
            state: state,
            inserted_at: now
          }

    Repo.insert_all(ClosedCycleIssue, rows, on_conflict: :nothing, conflict_target: [:cycle_id, :issue_id])

    next = Enum.find(cycles, &(Cycle.calculate_status(&1, today) != :ended))
    unfinished = for {issue_id, state} <- held, not Issue.finished_state?(state), do: issue_id

    Repo.update_all(from(i in Issue, where: i.project_id == ^project_id and i.id in ^unfinished),
      set: [cycle_external_id: next.id, updated_at: now]
    )
  end
end
