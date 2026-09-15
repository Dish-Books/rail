defmodule Rail.Repo.Migrations.CreateViewedFiles do
  @moduledoc false
  use Ecto.Migration

  def change do
    create table(:viewed_files) do
      add :task_id, references(:tasks, type: :text, on_delete: :delete_all), null: false
      add :user_id, references(:users, type: :text, on_delete: :delete_all), null: false
      add :path, :text, null: false
      add :digest, :text, null: false
      add :viewed_at, :utc_datetime_usec, null: false

      timestamps()
    end

    create unique_index(:viewed_files, [:task_id, :user_id, :path])
  end
end
