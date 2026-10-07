defmodule Rail.Repo.Migrations.AddSplitToTasks do
  use Ecto.Migration

  # A child of a split: its parent, its place in the split and the earlier places it builds on. A parent
  # with children is never deleted, since its children's worktrees would go with no row left to find them.
  def change do
    alter table(:tasks) do
      add :parent_task_id, references(:tasks, on_delete: :nothing)
      add :split_position, :integer
      add :builds_on, {:array, :integer}, null: false, default: []
    end
  end
end
