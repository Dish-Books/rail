defmodule Rail.Repo.Migrations.IndexIssuesChatTokenHash do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create index(:issues, [:chat_token_hash], where: "chat_token_hash IS NOT NULL", concurrently: true)
  end
end
