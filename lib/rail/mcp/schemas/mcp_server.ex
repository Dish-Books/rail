defmodule Rail.Mcp.Schemas.McpServer do
  @moduledoc """
  A remote MCP server Rail proxies for its agents.

  The list is global. Discovery fills in the OAuth endpoints and the client Rail
  registered with the server; each user then connects their own account. `name`
  also prefixes every tool the proxy exposes (`linear__get_issue`), so it is fixed
  to characters an agent CLI accepts in a tool name.
  """
  use Rail.Schema

  alias Rail.Mcp.Schemas.McpConnection
  alias Rail.Types.EncryptedBinary

  @auths [:oauth, :none]

  @primary_key {:id, UXID, autogenerate: true, prefix: "mcs"}
  schema "mcp_servers" do
    field :name, :string
    field :url, :string
    field :enabled, :boolean, default: true
    field :auth, Ecto.Enum, values: @auths, default: :oauth
    field :resource, :string
    field :authorization_endpoint, :string
    field :token_endpoint, :string
    field :registration_endpoint, :string
    field :scopes, {:array, :string}, default: []
    field :client_id, :string
    field :client_secret, EncryptedBinary, redact: true
    field :tools, {:array, :map}, default: []
    field :tools_refreshed_at, :utc_datetime_usec

    has_many :connections, McpConnection

    timestamps()
  end

  @cast_fields [
    :auth,
    :authorization_endpoint,
    :client_id,
    :client_secret,
    :enabled,
    :name,
    :registration_endpoint,
    :resource,
    :scopes,
    :token_endpoint,
    :tools,
    :tools_refreshed_at,
    :url
  ]

  @required_fields [:name, :url, :auth]

  def changeset(server, attrs) do
    server
    |> cast(attrs, @cast_fields)
    |> validate_required(@required_fields)
    |> validate_format(:name, ~r/^[a-z0-9_]+$/, message: "must be lowercase letters, digits and underscores")
    |> validate_format(:name, ~r/^(?!.*__)/, message: "must not contain a double underscore")
    |> validate_format(:url, ~r{^https?://[^\s]+$}, message: "must be an http(s) URL")
    |> unique_constraint(:name)
  end
end
