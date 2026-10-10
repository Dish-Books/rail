defmodule Rail.Repo.Migrations.IndexProjectsKey do
  @moduledoc false
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  # A GitHub project's key prefixes its issues' identifiers, so no two may share one.
  def change do
    create unique_index(:projects, [:key], where: "tracker = 'github'", concurrently: true)
  end
end
