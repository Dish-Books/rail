defmodule Rail.Repo.Migrations.RemoveIsUpdatingBranchFromTasks do
  @moduledoc false
  use Ecto.Migration

  # Agents bring their branch up to date themselves now, so Rail no longer holds a merge open on a task. One
  # left stopped on conflicts is the agent's to finish and commit on its next turn.
  def up do
    alter table(:tasks) do
      remove :is_updating_branch
    end
  end

  def down do
    alter table(:tasks) do
      add :is_updating_branch, :boolean, default: false, null: false
    end
  end
end
