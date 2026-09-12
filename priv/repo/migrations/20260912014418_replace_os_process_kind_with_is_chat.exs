defmodule Rail.Repo.Migrations.ReplaceOsProcessKindWithIsChat do
  use Ecto.Migration

  # Only `stage` and `chat` were ever written, and every read asked the same
  # question: does this process settle its task's stage, or is it a chat turn
  # alongside it?
  def up do
    alter table(:os_processes) do
      add :is_chat, :boolean, null: false, default: false
      # The first run_events seq this process wrote, so its own words can be read
      # back out of the run's shared log after it exits.
      add :start_seq, :integer, null: false, default: 1
    end

    execute "UPDATE os_processes SET is_chat = true WHERE kind = 'chat'"

    alter table(:os_processes) do
      remove :kind
    end
  end

  def down do
    alter table(:os_processes) do
      add :kind, :text
    end

    execute "UPDATE os_processes SET kind = CASE WHEN is_chat THEN 'chat' ELSE 'stage' END"
    execute "ALTER TABLE os_processes ALTER COLUMN kind SET NOT NULL"

    alter table(:os_processes) do
      remove :is_chat
      remove :start_seq
    end
  end
end
