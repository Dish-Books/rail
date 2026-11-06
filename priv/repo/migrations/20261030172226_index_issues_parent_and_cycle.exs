defmodule Rail.Repo.Migrations.IndexIssuesParentAndCycle do
  @moduledoc false
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  # Every list and issue page preloads sub-issues by parent, and the cycle view filters a project by cycle.
  def change do
    create index(:issues, [:parent_external_id], concurrently: true)
    create index(:issues, [:project_id, :cycle_external_id], concurrently: true)
  end
end
