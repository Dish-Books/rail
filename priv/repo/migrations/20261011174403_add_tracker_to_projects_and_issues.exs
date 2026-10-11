defmodule Rail.Repo.Migrations.AddTrackerToProjectsAndIssues do
  @moduledoc false
  use Ecto.Migration

  # A project tracks its issues in Linear or GitHub Issues. Its key is a Linear project's team key,
  # or the prefix a GitHub project names its issues with; an issue's external_updated_at is its
  # tracker's own updated_at, Linear's included.
  def change do
    rename table(:projects), :linear_team_key, to: :key

    alter table(:projects) do
      add :tracker, :text, null: false, default: "linear"
      modify :key, :citext, from: :text
    end

    rename table(:issues), :linear_updated_at, to: :external_updated_at

    alter table(:issues) do
      add :tracker, :text, null: false, default: "linear"
      add :number, :integer
    end

    # The worker was renamed AdvanceTrackerState, so a job still queued under its old name would find no module.
    execute(
      "UPDATE oban_jobs SET worker = 'Rail.Issues.Workers.AdvanceTrackerState' WHERE worker = 'Rail.Issues.Workers.AdvanceLinearState'",
      "SELECT 1"
    )
  end
end
