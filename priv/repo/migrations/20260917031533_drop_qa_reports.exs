defmodule Rail.Repo.Migrations.DropQaReports do
  @moduledoc false
  use Ecto.Migration

  # The QA stage of the old architecture captured a manifest into a row of its
  # own. Nothing has mapped this table since that code was left behind, and what
  # replaces it is `qa_findings` plus the report on disk.
  def up do
    drop table(:qa_reports)
  end

  def down do
    create table(:qa_reports) do
      add :task_id, :text, null: false
      add :run_id, :text
      add :commit, :text
      add :session, :map, default: "{}", null: false
      add :rows, :jsonb, default: "[]", null: false

      timestamps()
    end

    create index(:qa_reports, [:task_id])
  end
end
