defmodule Rail.Repo.Migrations.CreateRounds do
  use Ecto.Migration

  # One pass of a task from its plan through the engineer to its review, numbered from 1.
  def change do
    create table(:rounds) do
      add :task_id, references(:tasks, on_delete: :delete_all), null: false
      add :number, :integer, null: false
      add :plan, :text
      add :plan_version, :integer, null: false, default: 0
      add :plan_saved_at, :utc_datetime_usec
      add :record_demo, :boolean, null: false, default: false
      add :approved_by_id, references(:users, on_delete: :nilify_all)
      add :approved_at, :utc_datetime_usec
      add :base_head, :text
      add :head, :text
      add :reviewed_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec

      timestamps()
    end

    create unique_index(:rounds, [:task_id, :number])
  end
end
