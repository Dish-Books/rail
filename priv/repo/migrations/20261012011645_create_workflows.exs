defmodule Rail.Repo.Migrations.CreateWorkflows do
  use Ecto.Migration

  # One row per workflow file a project's default branch has had, kept after the file goes since issues point at it.
  def change do
    create table(:workflows) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :path, :text, null: false
      add :definition, :map
      add :paused, :boolean, null: false, default: false
      add :next_run_at, :utc_datetime
      add :removed_at, :utc_datetime_usec

      timestamps()
    end

    create unique_index(:workflows, [:project_id, :path])
    create index(:workflows, [:next_run_at])
  end
end
