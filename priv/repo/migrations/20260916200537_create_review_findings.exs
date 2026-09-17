defmodule Rail.Repo.Migrations.CreateReviewFindings do
  @moduledoc false
  use Ecto.Migration

  def change do
    create table(:review_findings) do
      add :task_id, references(:tasks, type: :text, on_delete: :delete_all), null: false
      add :key, :text, null: false
      add :title, :text, null: false
      add :detail, :text
      add :file, :text
      add :line, :integer
      add :severity, :text, null: false
      add :recommendation, :text, null: false
      add :status, :text, default: "open", null: false
      add :decision, :text, null: false

      timestamps()
    end

    create unique_index(:review_findings, [:task_id, :key])

    # The rework budget the old gate model kept. Findings replace it, and no
    # schema has mapped these since.
    alter table(:tasks) do
      remove :rework_cycles, :integer, default: 0, null: false
      remove :rework_budget_base, :integer, default: 0, null: false
      remove :rework_cycles_by_gate, :jsonb, default: "{}", null: false
      remove :outstanding_reports, :jsonb, default: "[]", null: false
    end
  end
end
