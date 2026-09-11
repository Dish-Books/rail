defmodule Rail.Repo.Migrations.AddScratchPathToTasks do
  @moduledoc """
  The scratch directory was recomputed at every call site, so the spawner, the
  briefs and the settle each derived it separately and could disagree. It becomes
  a column, written once when the task is created, the way `worktree_path` already is.
  """

  use Ecto.Migration

  def up do
    alter table(:tasks) do
      add :scratch_path, :text
    end

    flush()

    # The same path `Rail.Pipeline.Utils.ScratchPath.scratch_path/2` produces.
    root = Path.join(System.tmp_dir!(), "rail")

    execute("""
    UPDATE tasks
       SET scratch_path = '#{root}/' || project_id || '/scratch/' || id
     WHERE scratch_path IS NULL
    """)

    alter table(:tasks) do
      modify :scratch_path, :text, null: false
    end
  end

  def down do
    alter table(:tasks) do
      remove :scratch_path
    end
  end
end
