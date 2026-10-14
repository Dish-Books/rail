defmodule Rail.Repo.Migrations.AddBaseStatusToTasks do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add :base_behind, :boolean, null: false, default: false
      add :base_conflicts, {:array, :string}, null: false, default: []
      add :base_checked_at, :utc_datetime_usec
    end
  end
end
