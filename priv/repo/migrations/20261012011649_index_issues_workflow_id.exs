defmodule Rail.Repo.Migrations.IndexIssuesWorkflowId do
  @moduledoc false
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  # A workflow opens nothing while the last issue it opened is unfinished, read by this.
  def change do
    create index(:issues, [:workflow_id, :inserted_at], concurrently: true)
  end
end
