defmodule Rail.Repo.Migrations.CreateBrowserSessions do
  @moduledoc false
  use Ecto.Migration

  def change do
    create table(:browser_sessions) do
      add :task_id, references(:tasks, type: :text, on_delete: :delete_all), null: false
      add :node, :text, null: false
      add :os_pid, :integer
      add :debug_port, :integer
      add :profile_path, :text
      add :target_id, :text
      add :cdp_session_id, :text
      add :status, :text, default: "starting", null: false
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec

      timestamps()
    end

    # One live browser per task, not one ever: a task is QA'd more than once, and
    # each pass gets its own session. The finished rows stay as the record of what
    # was launched and what became of it.
    create unique_index(:browser_sessions, [:task_id],
             where: "status <> 'finished'",
             name: :browser_sessions_live_task_index
           )
    create index(:browser_sessions, [:node, :status])
  end
end
