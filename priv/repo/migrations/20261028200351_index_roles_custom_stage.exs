defmodule Rail.Repo.Migrations.IndexRolesCustomStage do
  @moduledoc false
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  # One role per custom stage name on a project, which two tasks entering it at once both upsert.
  def change do
    create unique_index(:roles, [:project_id, :custom_stage], concurrently: true)
  end
end
