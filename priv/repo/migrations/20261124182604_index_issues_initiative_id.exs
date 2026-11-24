defmodule Rail.Repo.Migrations.IndexIssuesInitiativeId do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create index(:issues, [:initiative_id], concurrently: true)
  end
end
