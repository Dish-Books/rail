defmodule Rail.Repo.Migrations.AddTrackerToProjectsAndIssues do
  @moduledoc false
  use Ecto.Migration

  # A project tracks its issues in Linear or GitHub Issues; only a Linear one needs a team key.
  def change do
    alter table(:projects) do
      add :tracker, :text, null: false, default: "linear"
      add :key, :citext
      modify :linear_team_key, :text, null: true, from: {:text, null: false}
    end

    create constraint(:projects, :linear_projects_have_team_key,
             check: "tracker <> 'linear' OR linear_team_key IS NOT NULL"
           )

    alter table(:issues) do
      add :tracker, :text, null: false, default: "linear"
      add :number, :integer
      add :external_updated_at, :utc_datetime_usec
    end
  end
end
