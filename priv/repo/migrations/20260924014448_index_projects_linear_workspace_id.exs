defmodule Rail.Repo.Migrations.IndexProjectsLinearWorkspaceId do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create index(:projects, [:linear_workspace_id], concurrently: true)
  end
end
