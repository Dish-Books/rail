defmodule Rail.Repo.Migrations.AddDocumentToViewedFiles do
  @moduledoc false
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  # A plan's card and the diff can name the same path, so each mark says which of the two it is on.
  def change do
    alter table(:viewed_files) do
      add :document, :text, null: false, default: "diff"
    end

    create unique_index(:viewed_files, [:task_id, :user_id, :document, :path], concurrently: true)
    drop index(:viewed_files, [:task_id, :user_id, :path], concurrently: true)

    # Run first on the way back, as the plan's marks would collide with the diff's on the old index.
    execute("SELECT 1", "DELETE FROM viewed_files WHERE document <> 'diff'")
  end
end
