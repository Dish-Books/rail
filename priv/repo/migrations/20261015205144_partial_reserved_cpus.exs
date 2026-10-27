defmodule Rail.Repo.Migrations.PartialReservedCpus do
  use Ecto.Migration

  # A role can reserve part of a CPU, so what it and its sandboxes hold is no longer whole.
  def change do
    alter table(:roles) do
      modify :reserved_cpus, :float, null: false, default: 1.0, from: {:integer, null: false, default: 1}
    end

    alter table(:os_processes) do
      modify :reserved_cpus, :float, from: :integer
    end
  end
end
