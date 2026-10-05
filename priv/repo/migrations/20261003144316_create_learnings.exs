defmodule Rail.Repo.Migrations.CreateLearnings do
  use Ecto.Migration

  def change do
    execute "CREATE EXTENSION IF NOT EXISTS vector", "DROP EXTENSION IF EXISTS vector"

    create table(:learnings) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :rule, :text, null: false
      add :why, :text
      add :kind, :text, null: false
      add :roles, {:array, :text}, null: false, default: []
      add :path_glob, :text
      add :status, :text, null: false
      add :auto, :boolean, null: false, default: false
      add :pinned, :boolean, null: false, default: false
      add :approved_by_id, references(:users, on_delete: :nilify_all)
      add :activated_at, :utc_datetime_usec
      add :retired_at, :utc_datetime_usec
      add :embedding, :vector, size: 3072
      add :embedding_model, :text

      timestamps()
    end

    create index(:learnings, [:project_id, :status])

    create table(:curator_passes) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :started_at, :utc_datetime_usec, null: false
      add :finished_at, :utc_datetime_usec
      add :error, :text
      add :digest_permalink, :text

      timestamps()
    end

    create index(:curator_passes, [:project_id, :started_at])

    create table(:observations) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :task_id, references(:tasks, on_delete: :nilify_all)
      add :source_kind, :text, null: false
      add :source_id, :text
      add :source_url, :text
      add :actor_id, references(:users, on_delete: :nilify_all)
      add :actor_name, :text
      add :text, :text, null: false
      add :excerpt, :text
      add :abandoned, :boolean, null: false, default: false
      add :learning_id, references(:learnings, on_delete: :nilify_all)
      add :curator_pass_id, references(:curator_passes, on_delete: :nilify_all)

      timestamps()
    end

    create unique_index(:observations, [:project_id, :source_kind, :source_id])
    create index(:observations, [:learning_id])
    create index(:observations, [:task_id])
    create index(:observations, [:project_id], where: "curator_pass_id IS NULL", name: :observations_unread_index)

    create table(:learning_proposals) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :action, :text, null: false
      add :title, :text
      add :summary, :text
      add :learning_id, references(:learnings, on_delete: :delete_all), null: false
      add :target_ids, {:array, :text}, null: false, default: []
      add :evidence_ids, {:array, :text}, null: false, default: []
      add :promote_to, :text
      add :issue_id, references(:issues, on_delete: :nilify_all)
      add :source_key, :text
      add :status, :text, null: false, default: "pending"
      add :decided_by_id, references(:users, on_delete: :nilify_all)
      add :decided_at, :utc_datetime_usec
      add :curator_pass_id, references(:curator_passes, on_delete: :nilify_all)

      timestamps()
    end

    create index(:learning_proposals, [:project_id, :status])
    create index(:learning_proposals, [:learning_id])
    create index(:learning_proposals, [:issue_id])
    create unique_index(:learning_proposals, [:project_id, :source_key])

    create unique_index(:learning_proposals, [:learning_id],
             where: "action = 'override' AND status = 'pending'",
             name: :learning_proposals_pending_override_index
           )

    create table(:learning_retrievals) do
      add :learning_id, references(:learnings, on_delete: :delete_all), null: false
      add :run_id, references(:runs, on_delete: :delete_all), null: false

      timestamps(updated_at: false)
    end

    create unique_index(:learning_retrievals, [:learning_id, :run_id])
    create index(:learning_retrievals, [:run_id])

    create table(:processed_pull_requests) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :number, :integer, null: false

      timestamps(updated_at: false)
    end

    create unique_index(:processed_pull_requests, [:project_id, :number])

    alter table(:review_findings) do
      add :rule_id, references(:learnings, on_delete: :nilify_all)
      add :suppressed_by_id, references(:learnings, on_delete: :nilify_all)
      add :decided_by_id, references(:users, on_delete: :nilify_all)
    end

    alter table(:qa_findings) do
      add :decided_by_id, references(:users, on_delete: :nilify_all)
    end

    alter table(:diff_comments) do
      add :context_text, :text
    end

    alter table(:tasks) do
      add :learnings_extracted_at, :utc_datetime_usec
    end

    alter table(:questions) do
      add :answered_by_id, references(:users, on_delete: :nilify_all)
      add :suggested_learning_id, references(:learnings, on_delete: :nilify_all)
      add :answered_by_rail, :boolean, null: false, default: false
    end
  end
end
