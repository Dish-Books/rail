defmodule Rail.Repo.Migrations.AddWorktreeSetup do
  use Ecto.Migration

  def up do
    alter table(:projects) do
      add :worktree_setup_script, :text
    end

    alter table(:tasks) do
      add :worktree_slot, :integer
      add :worktree_setup_at, :utc_datetime_usec
    end

    alter table(:os_processes) do
      add :kind, :text, default: "agent", null: false
      add :command, :text
      add :exit_code, :integer
      add :deadline_at, :utc_datetime_usec
    end

    # A task that has run has a worktree someone already set up by hand, if at all;
    # running a script over one mid-task could move its ports under a running server.
    execute "UPDATE tasks SET worktree_setup_at = now() WHERE EXISTS (SELECT 1 FROM runs WHERE runs.task_id = tasks.id)"
  end

  def down do
    alter table(:os_processes) do
      remove :deadline_at
      remove :exit_code
      remove :command
      remove :kind
    end

    alter table(:tasks) do
      remove :worktree_setup_at
      remove :worktree_slot
    end

    alter table(:projects) do
      remove :worktree_setup_script
    end
  end
end
