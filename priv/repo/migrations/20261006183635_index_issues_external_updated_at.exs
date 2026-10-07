defmodule Rail.Repo.Migrations.IndexIssuesExternalUpdatedAt do
  @moduledoc false
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  # The GitHub poll resumes from a project's latest external_updated_at.
  def change do
    create index(:issues, [:project_id, :external_updated_at], concurrently: true)
  end
end
