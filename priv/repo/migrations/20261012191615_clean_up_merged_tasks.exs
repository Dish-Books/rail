defmodule Rail.Repo.Migrations.CleanUpMergedTasks do
  @moduledoc false
  use Ecto.Migration

  # Tasks merged before a merge queued its own cleanup would otherwise sit on disk until someone clicked Clean up.
  def change do
    execute(
      """
      INSERT INTO oban_jobs (state, queue, worker, args, max_attempts)
      SELECT 'available', 'issues', 'Rail.Pipeline.Workers.CleanupMergedTask', jsonb_build_object('task_id', t.id), 5
      FROM tasks t
      WHERE t.cleaned_up_at IS NULL
        AND (t.merged_at IS NOT NULL
          OR (t.stage = 'merged' AND EXISTS (SELECT 1 FROM tasks c WHERE c.parent_task_id = t.id)))
      """,
      "SELECT 1"
    )
  end
end
