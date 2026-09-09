defmodule Rail.Repo.Migrations.CreateRunsAndRoleRuns do
  use Ecto.Migration

  def change do
    create table(:role_runs) do
      add :task_id, :text, null: false
      add :role_id, :text, null: false
      add :conversation_id, :text
      add :status, :text, null: false
      add :started_at, :utc_datetime_usec, null: false
      add :completed_at, :utc_datetime_usec
      add :exit_code, :integer
      add :output, :text
      add :error, :text
      add :pending_answer, :text
      add :pending_chat, :text
      add :usage, :map
      add :chat_usage, :map
      add :attempts, :integer, default: 0, null: false
      add :attempt_log_lines, :integer, default: 0, null: false
      add :auto_retries, :integer, default: 0, null: false
      add :pruned, :boolean, default: false, null: false
      add :chat_fingerprint_head_sha, :text
      add :chat_fingerprint_dirty_digest, :text
      add :stage_fingerprint_head_sha, :text
      add :stage_fingerprint_dirty_digest, :text

      timestamps()
    end

    create index(:role_runs, [:task_id, :role_id])
    create index(:role_runs, [:conversation_id])

    create table(:run_events) do
      add :role_run_id, references(:role_runs, type: :text, on_delete: :delete_all), null: false
      add :seq, :integer, null: false
      add :line, :text, null: false

      timestamps()
    end

    create index(:run_events, [:role_run_id, :seq])

    create table(:runs) do
      add :role_run_id, references(:role_runs, type: :text, on_delete: :delete_all), null: false
      add :task_id, :text, null: false
      add :kind, :text, null: false
      add :os_pid, :integer
      add :stream_path, :text, null: false
      add :node, :text, null: false
      add :boot_id, :text, null: false
      add :status, :text, null: false
      add :started_at, :utc_datetime_usec, null: false

      timestamps()
    end

    create index(:runs, [:node, :status])
    create index(:runs, [:role_run_id])
  end
end
