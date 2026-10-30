defmodule Rail.Repo.Migrations.AddCycleAndParentToIssues do
  @moduledoc false
  use Ecto.Migration

  def change do
    alter table(:issues) do
      add :cycle_external_id, :text
      # No foreign key: a sync can write a sub-issue before its parent, or a parent on another team never.
      add :parent_external_id, :text
    end

    # No scheduled job runs a Linear sync, so each project is queued one here to fill both in.
    execute(
      """
      INSERT INTO oban_jobs (state, queue, worker, args, max_attempts)
      SELECT 'available', 'issues', 'Rail.Issues.Workers.LinearSync',
        jsonb_build_object(
          'project_id', p.id,
          'started_at', to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
        ),
        5
      FROM projects p
      WHERE p.tracker = 'linear'
      """,
      "SELECT 1"
    )
  end
end
