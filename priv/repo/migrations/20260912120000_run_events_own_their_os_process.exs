defmodule Rail.Repo.Migrations.RunEventsOwnTheirOsProcess do
  use Ecto.Migration

  # Two jobs were riding on one hand-maintained counter: which process wrote a
  # line, and what order the run's lines go in. The first is a foreign key, and
  # the second is the database's to assign -- three separate readers of
  # `max(seq) + 1` raced each other to pick the next one.
  def up do
    alter table(:run_events) do
      add :os_process_id, references(:os_processes, type: :text, on_delete: :nilify_all)
    end

    create index(:run_events, [:os_process_id])

    # Each process owned the run's lines from its own start_seq up to the next
    # process's, which is exactly what the column now says outright.
    execute """
    UPDATE run_events e
    SET os_process_id = p.id
    FROM (
      SELECT id,
             run_id,
             start_seq,
             lead(start_seq) OVER (PARTITION BY run_id ORDER BY start_seq) AS next_start
      FROM os_processes
    ) p
    WHERE e.run_id = p.run_id
      AND e.seq >= p.start_seq
      AND (p.next_start IS NULL OR e.seq < p.next_start)
    """

    alter table(:os_processes) do
      remove :start_seq
    end

    # Existing seqs restart at 1 per run; the sequence starts past the highest of
    # them, so every new line still sorts after the ones already in its run.
    execute "CREATE SEQUENCE run_events_seq_seq OWNED BY run_events.seq"
    execute "SELECT setval('run_events_seq_seq', coalesce((SELECT max(seq) FROM run_events), 0) + 1, false)"
    execute "ALTER TABLE run_events ALTER COLUMN seq TYPE bigint"
    execute "ALTER TABLE run_events ALTER COLUMN seq SET DEFAULT nextval('run_events_seq_seq')"
  end

  def down do
    execute "ALTER TABLE run_events ALTER COLUMN seq DROP DEFAULT"
    execute "DROP SEQUENCE run_events_seq_seq"
    execute "ALTER TABLE run_events ALTER COLUMN seq TYPE integer"

    alter table(:os_processes) do
      add :start_seq, :integer, null: false, default: 1
    end

    execute """
    UPDATE os_processes p
    SET start_seq = coalesce((SELECT min(e.seq) FROM run_events e WHERE e.os_process_id = p.id), 1)
    """

    drop index(:run_events, [:os_process_id])

    alter table(:run_events) do
      remove :os_process_id
    end
  end
end
