defmodule Rail.Runs.PruneRunEvents do
  @moduledoc """
  Sweeps historical `run_events` and marks completed `role_runs` as pruned
  after a retention period (default 30 days).

  Outcome, error, exit_code, duration, and usage in `role_runs` survive unchanged;
  only raw stream events are removed. Active in-flight runs are never pruned.
  """

  import Ecto.Query

  alias Rail.Repo
  alias Rail.Runs.Schemas.RoleRun
  alias Rail.Runs.Schemas.RunEvent

  @default_retention_days 30

  @doc """
  Prunes `run_events` older than the retention cutoff and marks the corresponding
  `role_runs` as pruned.
  """
  def prune_run_events(opts \\ []) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    retention_days = Keyword.get(opts, :retention_days, @default_retention_days)
    cutoff = Keyword.get(opts, :cutoff) || DateTime.shift(now, day: -retention_days)

    Repo.transaction(fn ->
      # 1. Identify completed/settled role runs before cutoff (not running or starting)
      candidate_role_run_ids =
        Repo.all(
          from r in RoleRun,
            where:
              r.status not in [:running, :starting] and
                ((not is_nil(r.completed_at) and r.completed_at < ^cutoff) or
                   (is_nil(r.completed_at) and r.inserted_at < ^cutoff)),
            select: r.id
        )

      # 2. Also identify role runs with events older than cutoff (provided not running/starting)
      event_role_run_ids =
        Repo.all(
          from e in RunEvent,
            join: r in assoc(e, :role_run),
            where: r.status not in [:running, :starting] and e.inserted_at < ^cutoff,
            distinct: true,
            select: e.role_run_id
        )

      all_target_ids =
        candidate_role_run_ids
        |> Enum.concat(event_role_run_ids)
        |> Enum.uniq()

      # 3. Delete all events for these role runs
      {deleted_events_count, _ignored} =
        Repo.delete_all(
          from e in RunEvent,
            where: e.role_run_id in ^all_target_ids
        )

      # 4. Mark pruned: true on role_runs not yet marked as pruned
      {updated_role_runs_count, _ignored} =
        Repo.update_all(
          from(r in RoleRun, where: r.id in ^all_target_ids and r.pruned == false),
          set: [pruned: true, updated_at: now]
        )

      %{
        pruned_events: deleted_events_count,
        pruned_role_runs: updated_role_runs_count
      }
    end)
  end
end
