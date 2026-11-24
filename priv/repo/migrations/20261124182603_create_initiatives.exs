defmodule Rail.Repo.Migrations.CreateInitiatives do
  use Ecto.Migration

  def change do
    create table(:initiatives) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :name, :citext, null: false
      add :notes, :text, null: false, default: ""
      add :expected_on, :date
      timestamps()
    end

    create unique_index(:initiatives, [:project_id, :name])

    create table(:initiative_comments) do
      add :initiative_id, references(:initiatives, on_delete: :delete_all), null: false
      add :author_user_id, references(:users, on_delete: :nilify_all)
      add :body, :text, null: false
      timestamps()
    end

    create index(:initiative_comments, [:initiative_id, :inserted_at])

    alter table(:issues) do
      # Deleting an initiative leaves its tickets, with none.
      add :initiative_id, references(:initiatives, on_delete: :nilify_all)
      # A brief compares it with its own microsecond time.
      modify :completed_at, :utc_datetime_usec, from: :utc_datetime
    end
  end
end
