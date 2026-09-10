defmodule Rail.Repo.Migrations.CreateIssues do
  use Ecto.Migration

  def change do
    create table(:issues) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :external_id, :text, null: false
      add :identifier, :text, null: false
      add :title, :text, null: false
      add :description, :text
      add :state, :text, null: false
      add :state_name, :text
      add :branch_name, :text
      add :url, :text
      add :linear_created_at, :utc_datetime_usec
      add :linear_updated_at, :utc_datetime_usec

      timestamps()
    end

    create unique_index(:issues, [:external_id])
    create index(:issues, [:project_id])
    create index(:issues, [:identifier])
  end
end
