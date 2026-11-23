defmodule Rail.Repo.Migrations.TriageOneReplyAndChat do
  use Ecto.Migration

  def up do
    alter table(:triage_threads) do
      add :reply_text, :text
      add :reply_posted_at, :utc_datetime_usec
      add :reply_posted_by_id, references(:users, on_delete: :nilify_all)
      add :send_started_at, :utc_datetime_usec
      add :send_error, :text
      add :chat_read_at, :utc_datetime_usec
    end

    alter table(:triage_items) do
      add :ignored, :boolean, null: false, default: false
      add :sent_at, :utc_datetime_usec
      add :followup_text, :text
      add :followup_posted_at, :utc_datetime_usec
    end

    create table(:triage_chat_messages) do
      add :author, :text, null: false
      add :text, :text, null: false
      add :changes, :text
      add :user_id, references(:users, on_delete: :nilify_all)
      add :thread_id, references(:triage_threads, on_delete: :delete_all), null: false
      timestamps()
    end

    create index(:triage_chat_messages, [:thread_id, :inserted_at])

    flush()

    # Replies still to post become one draft, each placeholder filled with its item's ticket, or dropped
    # where people outside the team read the reply; a thread whose replies all went out keeps them as posted.
    execute """
    UPDATE triage_threads t
    SET reply_text = r.text, reply_posted_at = r.posted_at, reply_posted_by_id = r.posted_by_id
    FROM (
      SELECT i.thread_id,
        CASE WHEN bool_or(i.reply_posted_at IS NULL)
          THEN string_agg(
            replace(i.reply_text, '{issue link}',
              CASE WHEN coalesce(c.external, false) THEN '' ELSE coalesce(ci.identifier, ei.identifier, 'the ticket') END),
            E'\\n\\n' ORDER BY i.position) FILTER (WHERE i.reply_posted_at IS NULL)
          ELSE string_agg(i.reply_text, E'\\n\\n' ORDER BY i.position) END AS text,
        CASE WHEN bool_or(i.reply_posted_at IS NULL) THEN NULL ELSE max(i.reply_posted_at) END AS posted_at,
        CASE WHEN bool_or(i.reply_posted_at IS NULL) THEN NULL
          ELSE (array_agg(i.reply_posted_by_id ORDER BY i.reply_posted_at DESC))[1] END AS posted_by_id
      FROM triage_items i
      JOIN triage_threads th ON th.id = i.thread_id
      LEFT JOIN slack_channels c ON c.id = th.slack_channel_id
      LEFT JOIN issues ci ON ci.id = i.created_issue_id
      LEFT JOIN issues ei ON ei.id = i.existing_issue_id
      WHERE btrim(coalesce(i.reply_text, '')) <> ''
      GROUP BY i.thread_id
    ) r
    WHERE r.thread_id = t.id
    """

    # A created ticket's link already went out, and a Done thread's round is over.
    execute """
    UPDATE triage_items i SET sent_at = i.updated_at
    FROM triage_threads t
    WHERE i.thread_id = t.id AND (t.status = 'done' OR i.created_issue_id IS NOT NULL)
    """

    # A note becomes its author's line in the chat.
    execute """
    INSERT INTO triage_chat_messages (id, thread_id, user_id, author, text, inserted_at, updated_at)
    SELECT 'tct_' || substring(n.id from 5), n.thread_id, n.user_id, 'person',
      CASE WHEN n.assumption IS NULL THEN 'On item ' || i.position || ': ' || n.text
        ELSE 'On item ' || i.position || ', where you assumed "' || n.assumption || '": ' || n.text END,
      n.inserted_at, n.updated_at
    FROM triage_notes n JOIN triage_items i ON i.id = n.item_id
    """

    # A note whose pass has not run yet keeps its line owed; every other line was answered.
    execute """
    UPDATE triage_threads t SET chat_read_at = now()
    WHERE NOT EXISTS (SELECT 1 FROM triage_items i WHERE i.thread_id = t.id AND i.retriaging)
    """

    drop table(:triage_notes)

    alter table(:triage_items) do
      remove :reply_text
      remove :reply_posted_at
      remove :reply_posted_by_id
      remove :retriaging
      remove :retriaged_at
      remove :previous_verdict
      remove :error
    end

    alter table(:triage_threads) do
      remove :forced
    end
  end

  def down do
    alter table(:triage_threads) do
      add :forced, :boolean, null: false, default: false
      remove :reply_text
      remove :reply_posted_at
      remove :reply_posted_by_id
      remove :send_started_at
      remove :send_error
      remove :chat_read_at
    end

    alter table(:triage_items) do
      add :reply_text, :text
      add :reply_posted_at, :utc_datetime_usec
      add :reply_posted_by_id, references(:users, on_delete: :nilify_all)
      add :retriaging, :boolean, null: false, default: false
      add :retriaged_at, :utc_datetime_usec
      add :previous_verdict, :text
      add :error, :text
      remove :ignored
      remove :sent_at
      remove :followup_text
      remove :followup_posted_at
    end

    create table(:triage_notes) do
      add :text, :text, null: false
      add :assumption, :text
      add :thread_id, references(:triage_threads, on_delete: :delete_all), null: false
      add :item_id, references(:triage_items, on_delete: :delete_all)
      add :user_id, references(:users, on_delete: :nilify_all)
      timestamps()
    end

    create index(:triage_notes, [:thread_id])
    drop table(:triage_chat_messages)
  end
end
