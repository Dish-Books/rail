defmodule Rail.Repo.Migrations.CreatePipelineTables do
  use Ecto.Migration

  def change do
    create table(:tasks) do
      add :project_id, references(:projects, type: :text, on_delete: :delete_all), null: false
      add :issue_id, references(:issues, type: :text, on_delete: :nilify_all)
      add :owner_user_id, references(:users, type: :text, on_delete: :nilify_all)
      add :title, :text, null: false
      add :description, :text
      add :stage, :text, default: "product", null: false
      add :stage_state, :text, default: "queued", null: false
      add :worktree_name, :text
      add :worktree_path, :text
      add :pr_number, :integer
      add :pr_url, :text
      add :mergeability, :text
      add :pr_is_draft, :boolean
      add :is_rebasing, :boolean, default: false, null: false
      add :stage_state_before_rebase, :text
      add :active_chat_role_id, :text
      add :question_id, :text
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

    create table(:questions) do
      add :task_id, references(:tasks, type: :text, on_delete: :delete_all), null: false
      add :role_id, references(:roles, type: :text, on_delete: :nilify_all)
      add :prompt, :text, null: false
      add :options, :jsonb, default: "[]", null: false
      add :context_summary, :text
      add :answer, :text
      add :status, :text, default: "pending", null: false
      add :answered_at, :utc_datetime_usec

      timestamps()
    end

    create index(:questions, [:task_id])
    create index(:questions, [:status])

    create table(:plans) do
      add :task_id, references(:tasks, type: :text, on_delete: :delete_all), null: false
      add :content, :text, null: false
      add :captured_at, :utc_datetime_usec, null: false

      timestamps()
    end

    create index(:plans, [:task_id])
  end
end
