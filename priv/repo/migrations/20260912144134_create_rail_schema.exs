defmodule Rail.Repo.Migrations.CreateRailSchema do
  use Ecto.Migration

  def change do
    execute "CREATE EXTENSION IF NOT EXISTS citext", ""

    create table(:users) do
      add :github_id, :text, null: false
      add :login, :text, null: false
      add :name, :text
      add :email, :citext, null: false
      add :avatar_url, :text
      add :admin, :boolean, default: false, null: false
      add :github_token, :binary
      add :linear_user_id, :text
      add :linear_name, :text
      add :linear_access_token, :binary
      add :linear_refresh_token, :binary
      add :linear_token_expires_at, :utc_datetime_usec
      add :last_project_filter, :text

      timestamps()
    end

    create unique_index(:users, [:github_id])
    create unique_index(:users, [:login])
    create unique_index(:users, [:email])

    create table(:users_tokens) do
      add :user_id, references(:users, type: :text, on_delete: :delete_all), null: false
      add :token, :binary, null: false
      add :context, :text, null: false
      add :sent_to, :text

      timestamps(updated_at: false)
    end

    create index(:users_tokens, [:user_id])
    create unique_index(:users_tokens, [:context, :token])

    create table(:linear_workspaces) do
      add :name, :text, null: false
      add :external_id, :text, null: false
      add :token, :binary, null: false
      add :webhook_secret, :binary, null: false

      timestamps()
    end

    create unique_index(:linear_workspaces, [:external_id])

    create table(:projects) do
      add :name, :text, null: false
      add :github_repo, :text, null: false
      add :github_installation_id, :bigint, null: false
      add :default_branch, :text, default: "main", null: false
      add :linear_workspace_id, references(:linear_workspaces, type: :text, on_delete: :nilify_all)
      add :linear_team_id, :text, null: false
      add :linear_team_key, :text, null: false
      add :linear_state_ids, :map, default: %{}, null: false
      add :clone_path, :text, null: false
      add :active, :boolean, default: true, null: false

      timestamps()
    end

    create unique_index(:projects, [:github_repo])
    create index(:projects, [:linear_workspace_id])

    create table(:issues) do
      add :project_id, references(:projects, type: :text, on_delete: :delete_all), null: false
      add :owner_user_id, references(:users, type: :text, on_delete: :nilify_all)
      add :external_id, :text, null: false
      add :identifier, :text, null: false
      add :title, :text, null: false
      add :description, :text
      add :state, :text, null: false
      add :state_name, :text
      add :branch_name, :text
      add :url, :text
      add :priority, :text, default: "medium", null: false
      add :estimate, :integer
      add :linear_created_at, :utc_datetime_usec
      add :linear_updated_at, :utc_datetime_usec

      timestamps()
    end

    create unique_index(:issues, [:external_id])
    create index(:issues, [:project_id])
    create index(:issues, [:identifier])
    create index(:issues, [:owner_user_id])

    create table(:backends) do
      add :name, :text, null: false
      add :executable_path, :text, null: false
      add :models, :jsonb, default: "[]", null: false

      timestamps()
    end

    create unique_index(:backends, [:name])

    create table(:roles) do
      add :project_id, references(:projects, type: :text, on_delete: :delete_all), null: false
      add :backend_id, references(:backends, type: :text, on_delete: :restrict), null: false
      add :stage, :text
      add :name, :text, null: false
      add :description, :text
      add :icon_name, :text, default: "pi-robot", null: false
      add :model, :text, null: false
      add :reasoning_effort, :text
      add :system_prompt, :text, null: false
      add :max_concurrent, :integer, default: 1, null: false
      add :position, :integer, default: 0, null: false

      timestamps()
    end

    create index(:roles, [:project_id])
    create index(:roles, [:backend_id])
    create unique_index(:roles, [:project_id, :stage], where: "stage IS NOT NULL", name: :roles_project_id_stage_index)

    create table(:tasks) do
      add :project_id, references(:projects, type: :text, on_delete: :delete_all), null: false
      add :issue_id, references(:issues, type: :text, on_delete: :nilify_all)
      add :stage, :text, default: "product", null: false
      add :stage_state, :text, default: "queued", null: false
      add :worktree_name, :text, null: false
      add :worktree_path, :text, null: false
      add :scratch_path, :text, null: false
      add :pr_number, :integer
      add :pr_url, :text
      add :mergeability, :text
      add :pr_is_draft, :boolean
      add :is_rebasing, :boolean, default: false, null: false
      add :stage_state_before_rebase, :text
      add :active_chat_role_id, :text
      add :error, :text
      add :retry_after, :utc_datetime_usec
      add :rework_cycles, :integer, default: 0, null: false
      add :rework_budget_base, :integer, default: 0, null: false
      add :rework_cycles_by_gate, :jsonb, default: "{}", null: false
      add :outstanding_reports, :jsonb, default: "[]", null: false
      add :viewed_diff_files, :jsonb, default: "[]", null: false
      add :merged_at, :utc_datetime_usec

      timestamps()
    end

    create index(:tasks, [:project_id])
    create index(:tasks, [:issue_id])
    create index(:tasks, [:stage, :stage_state])

    create table(:runs) do
      add :task_id, :text, null: false
      add :role_id, :text, null: false
      add :conversation_id, :text
      add :status, :text, null: false
      add :started_at, :utc_datetime_usec, null: false
      add :completed_at, :utc_datetime_usec
      add :exit_code, :integer
      add :error, :text
      add :pending_answer, :text
      add :pending_chat, :text
      add :usage, :map
      add :chat_usage, :map
      add :attempts, :integer, default: 0, null: false
      add :attempt_log_lines, :integer, default: 0, null: false
      add :auto_retries, :integer, default: 0, null: false
      add :chat_fingerprint_head_sha, :text
      add :chat_fingerprint_dirty_digest, :text
      add :stage_fingerprint_head_sha, :text
      add :stage_fingerprint_dirty_digest, :text

      timestamps()
    end

    create index(:runs, [:task_id, :role_id])
    create index(:runs, [:conversation_id])

    create table(:os_processes) do
      add :run_id, references(:runs, type: :text, on_delete: :delete_all), null: false
      add :task_id, :text, null: false
      add :os_pid, :integer
      add :stream_path, :text, null: false
      add :node, :text, null: false
      add :status, :text, null: false
      add :is_chat, :boolean, default: false, null: false
      add :started_at, :utc_datetime_usec, null: false

      timestamps()
    end

    create index(:os_processes, [:node, :status])
    create index(:os_processes, [:run_id])

    # `seq` orders a run's log lines across every process that wrote them, so it
    # is handed out by one sequence rather than computed per insert.
    create table(:run_events) do
      add :run_id, references(:runs, type: :text, on_delete: :delete_all), null: false
      add :os_process_id, references(:os_processes, type: :text, on_delete: :nilify_all)
      add :seq, :bigserial, null: false
      add :line, :text, null: false

      timestamps()
    end

    create index(:run_events, [:run_id, :seq])
    create index(:run_events, [:os_process_id])

    create table(:questions) do
      add :task_id, references(:tasks, type: :text, on_delete: :delete_all), null: false
      add :run_id, references(:runs, type: :text, on_delete: :delete_all), null: false
      add :prompt, :text, null: false
      add :options, :jsonb, default: "[]", null: false
      add :context_summary, :text
      add :answer, :text
      add :status, :text, default: "pending", null: false
      add :answered_at, :utc_datetime_usec
      add :delivered_at, :utc_datetime_usec

      timestamps()
    end

    create index(:questions, [:task_id])
    create index(:questions, [:run_id])
    create index(:questions, [:status])
    create index(:questions, [:task_id, :status])

    create table(:plans) do
      add :task_id, references(:tasks, type: :text, on_delete: :delete_all), null: false
      add :content, :text, null: false
      add :captured_at, :utc_datetime_usec, null: false

      timestamps()
    end

    create index(:plans, [:task_id])

    create table(:designs) do
      add :task_id, :text, null: false
      add :version, :integer, default: 1, null: false
      add :canvas_url, :text, null: false
      add :picked_key, :text
      add :directions, :jsonb, default: "[]", null: false
      add :linear_comment_id, :text

      timestamps()
    end

    create index(:designs, [:task_id])
    create unique_index(:designs, [:task_id, :version])

    create table(:demos) do
      add :task_id, :text, null: false
      add :version, :integer, default: 1, null: false
      add :recorded_at, :utc_datetime_usec, null: false
      add :commit, :text
      add :head_sha, :text
      add :dirty_digest, :text
      add :outcome, :text, null: false
      add :note, :text
      add :stale, :boolean, default: false, null: false
      add :segments, :jsonb, default: "[]", null: false
      add :linear_comment_id, :text

      timestamps()
    end

    create index(:demos, [:task_id])
    create unique_index(:demos, [:task_id, :version])

    create table(:qa_reports) do
      add :task_id, :text, null: false
      add :run_id, :text
      add :commit, :text
      add :session, :map, default: "{}", null: false
      add :rows, :jsonb, default: "[]", null: false

      timestamps()
    end

    create index(:qa_reports, [:task_id])

    create table(:cli_accounts) do
      add :node, :text, null: false
      add :backend, :text, null: false
      add :status, :text, null: false
      add :account_label, :text
      add :account_detail, :text
      add :groups, :jsonb, default: "[]", null: false
      add :fetched_at, :utc_datetime_usec
      add :unavailable_reason, :text

      timestamps()
    end

    create unique_index(:cli_accounts, [:node, :backend], name: :cli_accounts_node_backend_index)
  end
end
