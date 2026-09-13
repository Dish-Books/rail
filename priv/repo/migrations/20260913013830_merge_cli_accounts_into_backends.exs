defmodule Rail.Repo.Migrations.MergeCliAccountsIntoBackends do
  use Ecto.Migration

  def up do
    # A backend row now carries both the config the user owns and what the last
    # usage probe found, so there is nothing left for cli_accounts to hold.
    alter table(:backends) do
      add :status, :text, default: "not_configured", null: false
      add :account_label, :text
      add :account_detail, :text
      add :usage, :jsonb, default: "[]", null: false
      add :fetched_at, :utc_datetime_usec
      add :unavailable_reason, :text
    end

    # A probe can land before the user has configured a path, so the column has
    # to hold a blank until the settings form fills it in.
    execute "ALTER TABLE backends ALTER COLUMN executable_path SET DEFAULT ''"

    drop table(:cli_accounts)
  end

  def down do
    execute "ALTER TABLE backends ALTER COLUMN executable_path DROP DEFAULT"

    alter table(:backends) do
      remove :status
      remove :account_label
      remove :account_detail
      remove :usage
      remove :fetched_at
      remove :unavailable_reason
    end

    create table(:cli_accounts, primary_key: false) do
      add :id, :text, primary_key: true
      add :node, :text, null: false
      add :backend, :text, null: false
      add :status, :text, null: false
      add :account_label, :text
      add :account_detail, :text
      add :groups, :jsonb, default: "[]", null: false
      add :fetched_at, :utc_datetime_usec
      add :unavailable_reason, :text

      timestamps()
    end

    create unique_index(:cli_accounts, [:node, :backend], name: :cli_accounts_node_backend_index)
  end
end
