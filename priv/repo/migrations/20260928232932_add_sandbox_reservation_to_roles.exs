defmodule Rail.Repo.Migrations.AddSandboxReservationToRoles do
  use Ecto.Migration

  def change do
    alter table(:roles) do
      add :reserved_cpus, :integer, null: false, default: 1
      add :reserved_memory_gb, :integer, null: false, default: 2
    end
  end
end
