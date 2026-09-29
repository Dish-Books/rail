defmodule Rail.Repo.Migrations.IndexOsProcessesStatusQueuedAt do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create index(:os_processes, [:status, :queued_at], concurrently: true)
  end
end
