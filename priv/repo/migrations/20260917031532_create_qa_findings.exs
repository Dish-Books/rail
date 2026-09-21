defmodule Rail.Repo.Migrations.CreateQaFindings do
  @moduledoc false
  use Ecto.Migration

  def change do
    create table(:qa_findings) do
      add :task_id, references(:tasks, type: :text, on_delete: :delete_all), null: false
      add :key, :text, null: false
      add :title, :text, null: false
      add :check, :text, null: false
      add :criterion, :text
      add :screen, :text
      add :steps, :text
      add :expected, :text
      add :observed, :text
      add :detail, :text
      add :suggestion, :text
      add :severity, :text, null: false
      add :recommendation, :text, null: false
      add :status, :text, default: "open", null: false
      add :caused_by_change, :boolean, default: true, null: false
      add :evidence, :jsonb, default: "[]", null: false

      # The human's alone, and nothing until they say so.
      add :decision, :text

      timestamps()
    end

    create unique_index(:qa_findings, [:task_id, :key])
  end
end
