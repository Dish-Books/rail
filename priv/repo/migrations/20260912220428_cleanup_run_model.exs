defmodule Rail.Repo.Migrations.CleanupRunModel do
  use Ecto.Migration

  def up do
    rename table(:plans), to: table(:implementation_plans)
    create unique_index(:implementation_plans, [:task_id])

    alter table(:runs) do
      remove :attempts
      remove :attempt_log_lines
    end

    alter table(:tasks) do
      remove :error
    end

    Oban.Migration.up(version: 14)
  end

  def down do
    Oban.Migration.down(version: 1)

    alter table(:tasks) do
      add :error, :text
    end

    alter table(:runs) do
      add :attempt_log_lines, :integer, default: 0, null: false
      add :attempts, :integer, default: 0, null: false
    end

    drop unique_index(:implementation_plans, [:task_id])
    rename table(:implementation_plans), to: table(:plans)
  end
end
