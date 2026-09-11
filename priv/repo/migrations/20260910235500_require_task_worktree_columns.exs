defmodule Rail.Repo.Migrations.RequireTaskWorktreeColumns do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE tasks SET worktree_name = id WHERE worktree_name IS NULL OR worktree_name = ''
    """)

    execute("""
    UPDATE tasks
    SET worktree_path = p.clone_path || '/.worktrees/' || tasks.worktree_name
    FROM projects p
    WHERE p.id = tasks.project_id AND (tasks.worktree_path IS NULL OR tasks.worktree_path = '')
    """)

    alter table(:tasks) do
      modify :worktree_name, :text, null: false
      modify :worktree_path, :text, null: false
    end
  end

  def down do
    alter table(:tasks) do
      modify :worktree_name, :text, null: true
      modify :worktree_path, :text, null: true
    end
  end
end
