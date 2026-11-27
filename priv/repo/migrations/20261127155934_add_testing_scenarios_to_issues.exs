defmodule Rail.Repo.Migrations.AddTestingScenariosToIssues do
  use Ecto.Migration

  def change do
    alter table(:issues) do
      add :testing_scenarios, :jsonb, null: false, default: "[]"
      add :testing_environment, :text
      add :testing_platform, :text
      add :testing_device, :text
      add :no_scenarios_reason, :text
      add :scenarios_requested_at, :utc_datetime
      add :scenarios_started_at, :utc_datetime
    end
  end
end
