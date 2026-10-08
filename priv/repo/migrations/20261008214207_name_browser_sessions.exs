defmodule Rail.Repo.Migrations.NameBrowserSessions do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    alter table(:browser_sessions) do
      add :name, :text
      add :account, :text
    end

    # A row is named for the QA or demo run that drove it: the latest one on its
    # task started before it, else the stage the task is at now.
    execute """
    UPDATE browser_sessions s SET name = COALESCE(
      (SELECT ro.stage FROM runs r JOIN roles ro ON ro.id = r.role_id
       WHERE r.task_id = s.task_id AND ro.stage IN ('qa', 'demo') AND r.started_at <= s.started_at
       ORDER BY r.started_at DESC LIMIT 1),
      (SELECT t.stage FROM tasks t WHERE t.id = s.task_id AND t.stage IN ('qa', 'demo')),
      'qa'
    )
    """

    alter table(:browser_sessions) do
      modify :name, :text, null: false
    end

    create unique_index(:browser_sessions, [:task_id, :name],
             where: "status <> 'finished'",
             name: :browser_sessions_live_task_name_index,
             concurrently: true
           )

    drop index(:browser_sessions, [:task_id], name: :browser_sessions_live_task_index, concurrently: true)
  end

  def down do
    drop index(:browser_sessions, [:task_id, :name], name: :browser_sessions_live_task_name_index, concurrently: true)

    create unique_index(:browser_sessions, [:task_id],
             where: "status <> 'finished'",
             name: :browser_sessions_live_task_index,
             concurrently: true
           )

    alter table(:browser_sessions) do
      remove :name
      remove :account
    end
  end
end
