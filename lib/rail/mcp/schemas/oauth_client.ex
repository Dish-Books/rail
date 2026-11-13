defmodule Rail.Mcp.Schemas.OauthClient do
  @moduledoc """
  An MCP client that registered itself with Rail, by RFC 7591 registration or a client ID metadata document. Only the
  SHA-256 of a confidential client's secret is kept; the client sees the secret once.
  """
  use Rail.Schema

  @primary_key {:id, UXID, autogenerate: true, prefix: "oac"}
  schema "oauth_clients" do
    field :name, :string
    field :client_id, :string
    field :client_secret_hash, :binary, redact: true
    field :redirect_uris, {:array, :string}
    field :registration, Ecto.Enum, values: [:dynamic, :metadata_document]

    field :token_endpoint_auth_method, Ecto.Enum,
      values: [:none, :client_secret_basic, :client_secret_post],
      default: :none

    field :metadata_fetched_at, :utc_datetime_usec

    timestamps()
  end

  def dynamic_changeset(attrs) do
    %__MODULE__{registration: :dynamic}
    |> cast(attrs, [:name, :client_id, :client_secret_hash, :redirect_uris, :token_endpoint_auth_method])
    |> validate_required([:name, :client_id, :redirect_uris, :token_endpoint_auth_method])
    |> validate_redirect_uris()
    |> unique_constraint(:client_id)
  end

  def metadata_document_changeset(client, attrs) do
    client
    |> cast(attrs, [:name, :client_id, :redirect_uris, :metadata_fetched_at])
    |> put_change(:registration, :metadata_document)
    |> put_change(:token_endpoint_auth_method, :none)
    |> validate_required([:name, :client_id, :redirect_uris, :metadata_fetched_at])
    |> validate_redirect_uris()
    |> unique_constraint(:client_id)
  end

  # Exact URIs: https, or http on a loopback host (RFC 8252 §7.3).
  defp validate_redirect_uris(changeset) do
    validate_change(changeset, :redirect_uris, fn :redirect_uris, uris ->
      cond do
        uris == [] -> [redirect_uris: "must have at least one redirect URI"]
        Enum.all?(uris, &redirect_uri?/1) -> []
        true -> [redirect_uris: "must use https, or http on localhost"]
      end
    end)
  end

  defp redirect_uri?(uri) do
    case URI.parse(uri) do
      %URI{scheme: "https", host: host, fragment: nil} when is_binary(host) and host != "" -> true
      %URI{scheme: "http", host: host, fragment: nil} when host in ["localhost", "127.0.0.1", "::1"] -> true
      _other -> false
    end
  end
end
