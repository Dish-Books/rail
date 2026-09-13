defmodule Rail.Repo.Migrations.CleanupRunModel do
  use Ecto.Migration

  def up do
    rename table(:plans), to: table(:implementation_plans)

    # The constraint keeps the old table's name through a rename, and Ecto derives
    # the new one from the schema, so they have to be brought back together.
    execute "ALTER TABLE implementation_plans RENAME CONSTRAINT plans_task_id_fkey TO implementation_plans_task_id_fkey"
    execute "ALTER TABLE implementation_plans RENAME CONSTRAINT plans_pkey TO implementation_plans_pkey"

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

    execute "ALTER TABLE implementation_plans RENAME CONSTRAINT implementation_plans_task_id_fkey TO plans_task_id_fkey"
    execute "ALTER TABLE implementation_plans RENAME CONSTRAINT implementation_plans_pkey TO plans_pkey"

    rename table(:implementation_plans), to: table(:plans)
  end
end
