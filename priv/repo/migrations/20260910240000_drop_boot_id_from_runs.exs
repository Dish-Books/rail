defmodule Rail.Repo.Migrations.DropBootIdFromRuns do
  @moduledoc """
  Boot reconciliation identifies adoptable runs by node and OS PID liveness;
  the boot identifier was recorded on every run but never read.
  """

  use Ecto.Migration

  def change do
    alter table(:runs) do
      remove :boot_id, :text, null: false
    end
  end
end
