defmodule Rail.Mcp.Schemas.McpConnection do
  @moduledoc """
  One user's OAuth tokens for one MCP server.
  """
  use Rail.Schema

  alias Rail.Mcp.Schemas.McpServer
  alias Rail.Types.EncryptedBinary
  alias Rail.Users.Schemas.User

  @primary_key {:id, UXID, autogenerate: true, prefix: "mcc"}
  schema "mcp_connections" do
    field :access_token, EncryptedBinary, redact: true
    field :refresh_token, EncryptedBinary, redact: true
    field :expires_at, :utc_datetime_usec
    field :scope, :string

    belongs_to :user, User
    belongs_to :mcp_server, McpServer

    timestamps()
  end

  @cast_fields [:user_id, :mcp_server_id, :access_token, :refresh_token, :expires_at, :scope]
  @required_fields [:user_id, :mcp_server_id, :access_token]

  def changeset(connection, attrs) do
    connection
    |> cast(attrs, @cast_fields)
    |> validate_required(@required_fields)
    |> unique_constraint([:user_id, :mcp_server_id])
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:mcp_server_id)
  end
end
