defmodule Rail.Repo.Migrations.AddSandboxFieldsToOsProcesses do
  use Ecto.Migration

  def change do
    alter table(:os_processes) do
      add :runtime, :text, null: false, default: "local"
      add :container_id, :text
      add :reserved_cpus, :integer
      add :reserved_memory_gb, :integer
      add :queued_at, :utc_datetime_usec
      # Encrypted: it carries the turn's MCP token and CI's git credentials.
      add :launch, :binary
      add :ended_at, :utc_datetime_usec
      add :ended_reason, :text
      add :stopped_by_id, references(:users, on_delete: :nilify_all)
      add :restarts, :integer, null: false, default: 0
    end
  end
end
