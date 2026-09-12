defmodule Rail.Repo.Migrations.DropLiveSyncPublication do
  use Ecto.Migration

  # Logical replication is gone; PubSub carries every change the UI reacts to.
  def up do
    execute("DROP PUBLICATION IF EXISTS live_sync;")
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'live_sync') THEN
        CREATE PUBLICATION live_sync FOR TABLE tasks, issues, roles;
      END IF;
    END $$;
    """)
  end
end
