defmodule Rail.Repo.Migrations.IndexIssuesProjectIdNumber do
  @moduledoc false
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  # Only Rail numbers its own issues; GitHub's numbers are GitHub's to keep apart.
  def change do
    create unique_index(:issues, [:project_id, :number], where: "tracker = 'local'", concurrently: true)
  end
end
