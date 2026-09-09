defmodule Rail.Repo.Migrations.CreateCliAccounts do
  use Ecto.Migration

  def change do
    create table(:cli_accounts) do
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
