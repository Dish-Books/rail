defmodule Rail.Repo.Migrations.CreateLiveSyncPublication do
  use Ecto.Migration

  def up do
    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'live_sync') THEN
        CREATE PUBLICATION live_sync FOR TABLE tasks, issues, roles;
      END IF;
    END $$;
    """)
  end

  def down do
    execute("DROP PUBLICATION IF EXISTS live_sync;")
  end
end
