defmodule Rail.Repo.Migrations.DropDesignsAndDemos do
  @moduledoc false
  use Ecto.Migration

  # Designs and demos are saved in the task's scratch folder now. Nothing has mapped
  # these tables since, and with no foreign key to tasks their rows outlived them.
  def up do
    drop table(:designs)
    drop table(:demos)
  end

  def down do
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
  end
end
