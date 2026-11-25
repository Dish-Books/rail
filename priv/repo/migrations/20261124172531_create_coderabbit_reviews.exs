defmodule Rail.Repo.Migrations.CreateCoderabbitReviews do
  use Ecto.Migration

  def change do
    create table(:coderabbit_reviews) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :task_id, references(:tasks, on_delete: :delete_all), null: false
      # A review spent stays on the task's count even if the person who asked for it is gone.
      add :requested_by_id, references(:users, on_delete: :nilify_all)
      add :pr_number, :integer, null: false
      add :round, :integer, null: false
      add :head_sha, :text, null: false
      add :command, :text, null: false
      add :external_id, :bigint
      add :status, :text, null: false, default: "requested"
      add :comment_count, :integer
      add :finished_at, :utc_datetime_usec
      timestamps()
    end

    create index(:coderabbit_reviews, [:task_id])
    create index(:coderabbit_reviews, [:project_id, :pr_number, :status])
  end
end
