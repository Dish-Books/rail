defmodule Rail.Repo.Migrations.DropReadyToMergeStage do
  use Ecto.Migration

  # A task is ready to merge once its demo is recorded, which the demo stage
  # already says; there is no stage after it for a task to wait in.
  def up do
    execute "UPDATE tasks SET stage = 'demo' WHERE stage = 'ready_to_merge'"
  end

  def down, do: :ok
end
