defmodule Rail.Repo.Migrations.DropMemoryReservations do
  use Ecto.Migration

  # Memory is no longer reserved or limited: a sandbox takes what it needs, and only CPUs decide what runs at once.
  def change do
    alter table(:roles) do
      remove :reserved_memory_gb, :integer, null: false, default: 2
    end

    alter table(:os_processes) do
      remove :reserved_memory_gb, :integer
    end
  end
end
