defmodule Rail.Repo.Migrations.CreateArtifactsTables do
  use Ecto.Migration

  def change do
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
      add :role_run_id, :text
      add :commit, :text
      add :session, :map, default: "{}", null: false
      add :rows, :jsonb, default: "[]", null: false

      timestamps()
    end

    create index(:qa_reports, [:task_id])
  end
end
