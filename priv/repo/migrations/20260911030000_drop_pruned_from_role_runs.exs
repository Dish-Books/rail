defmodule Rail.Repo.Migrations.DropPrunedFromRoleRuns do
  use Ecto.Migration

  def up do
    alter table(:role_runs) do
      remove :pruned
    end
  end

  def down do
    alter table(:role_runs) do
      add :pruned, :boolean, null: false, default: false
    end
  end
end
