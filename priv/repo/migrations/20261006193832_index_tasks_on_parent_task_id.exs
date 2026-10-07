defmodule Rail.Repo.Migrations.IndexTasksOnParentTaskId do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  # Lists a parent's children in order, and refuses a second set of them.
  def change do
    create unique_index(:tasks, [:parent_task_id, :split_position], concurrently: true)
  end
end
