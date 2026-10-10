defmodule Rail.Repo.Migrations.MoveAdvanceLinearStateJobs do
  use Ecto.Migration

  # The worker was renamed AdvanceTrackerState and its old name is gone, so a job still queued
  # under the old name would find no module to run.
  def up do
    execute """
    UPDATE oban_jobs SET worker = 'Rail.Issues.Workers.AdvanceTrackerState'
    WHERE worker = 'Rail.Issues.Workers.AdvanceLinearState'
    """
  end

  def down, do: :ok
end
