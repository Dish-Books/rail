defmodule Rail.Repo.Migrations.IndexProjectsKey do
  @moduledoc false
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  # A key names a project's issues and branches, so no two projects share one, whatever their tracker.
  def change do
    create unique_index(:projects, [:key], concurrently: true)
  end
end
