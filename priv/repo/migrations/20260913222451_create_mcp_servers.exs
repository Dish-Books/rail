defmodule Rail.Repo.Migrations.CreateMcpServers do
  @moduledoc false
  use Ecto.Migration

  def change do
    create table(:mcp_servers) do
      add :name, :text, null: false
      add :url, :text, null: false
      add :enabled, :boolean, default: true, null: false
      add :auth, :text, default: "oauth", null: false
      add :resource, :text
      add :authorization_endpoint, :text
      add :token_endpoint, :text
      add :registration_endpoint, :text
      add :scopes, {:array, :text}, default: [], null: false
      add :client_id, :text
      add :client_secret, :binary
      add :tools, {:array, :map}, default: [], null: false
      add :tools_refreshed_at, :utc_datetime_usec

      timestamps()
    end

    create unique_index(:mcp_servers, [:name])

    create table(:mcp_connections) do
      add :user_id, references(:users, type: :text, on_delete: :delete_all), null: false
      add :mcp_server_id, references(:mcp_servers, type: :text, on_delete: :delete_all), null: false
      add :access_token, :binary, null: false
      add :refresh_token, :binary
      add :expires_at, :utc_datetime_usec
      add :scope, :text

      timestamps()
    end

    create unique_index(:mcp_connections, [:user_id, :mcp_server_id])
    create index(:mcp_connections, [:mcp_server_id])

    alter table(:roles) do
      add :mcp_tools, {:array, :text}, default: [], null: false
    end

    alter table(:os_processes) do
      add :mcp_token_hash, :binary
    end

    create unique_index(:os_processes, [:mcp_token_hash])
  end
end
