defmodule Rail.Repo.Migrations.IndexLearningLinks do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create index(:review_findings, [:rule_id], concurrently: true)
    create index(:review_findings, [:suppressed_by_id], concurrently: true)
    create index(:questions, [:suggested_learning_id], concurrently: true)
  end
end
