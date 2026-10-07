defmodule Rail.Repo.Migrations.ClearPlanDidNotStartErrors do
  use Ecto.Migration

  # Accepting an item no longer starts Plan, so the error it stored when Plan failed to start
  # goes; any other error, such as a failed Slack post's, stays.
  def up do
    execute "UPDATE triage_items SET error = NULL WHERE error LIKE 'Created %, but Plan did not start: %'"
  end

  def down, do: :ok
end
