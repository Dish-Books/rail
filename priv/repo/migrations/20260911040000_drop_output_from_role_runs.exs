defmodule Rail.Repo.Migrations.DropOutputFromRoleRuns do
  use Ecto.Migration

  def up do
    alter table(:role_runs) do
      remove :output
    end
  end

  def down do
    alter table(:role_runs) do
      add :output, :text
    end
  end
end
