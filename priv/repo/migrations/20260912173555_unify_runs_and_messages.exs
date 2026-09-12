defmodule Rail.Repo.Migrations.UnifyRunsAndMessages do
  use Ecto.Migration

  def change do
    # A run latches to `done` when its stage says so, and back to `in_progress`
    # when a later stage sends the work back. It is what stops a message that
    # arrives after the fact from re-applying a stage's finish.
    alter table(:runs) do
      add :stage_outcome, :text, default: "in_progress", null: false

      # Chat is no longer a separate kind of work, so it needs no separate
      # usage accumulator and no separate branch fingerprint.
      remove :chat_usage, :map
      remove :chat_fingerprint_head_sha, :text
      remove :chat_fingerprint_dirty_digest, :text
      remove :auto_retries, :integer, default: 0, null: false
    end

    # A task's state is a property of its runs, read off one run at a time.
    drop index(:tasks, [:stage, :stage_state])

    # A rebase never moved the stage, only parked `stage_state` to restore it
    # afterwards, so with that gone `is_rebasing` is the whole flag.
    alter table(:tasks) do
      remove :stage_state, :text, default: "queued", null: false
      remove :stage_state_before_rebase, :text
      remove :retry_after, :utc_datetime_usec
      remove :active_chat_role_id, :text
    end

    create index(:tasks, [:stage])

    alter table(:os_processes) do
      remove :is_chat, :boolean, default: false, null: false
    end
  end
end
