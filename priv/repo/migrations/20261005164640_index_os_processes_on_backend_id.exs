defmodule Rail.Repo.Migrations.IndexOsProcessesOnBackendId do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  # The pick counts each account's turns still in flight.
  def change do
    create index(:os_processes, [:backend_id, :status], concurrently: true)
  end
end
