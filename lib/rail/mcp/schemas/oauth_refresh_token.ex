defmodule Rail.Mcp.Schemas.OauthRefreshToken do
  @moduledoc """
  The token paired with an access token, presented at `/oauth/token` to rotate both into a new pair of the same family.
  """
  use Rail.Schema

  alias Rail.Mcp.Schemas.OauthAccessToken
  alias Rail.Mcp.Schemas.OauthClient
  alias Rail.Users.Schemas.User

  @primary_key {:id, UXID, autogenerate: true, prefix: "ort"}
  schema "oauth_refresh_tokens" do
    field :selector, :string
    field :verifier_hash, :binary, redact: true
    field :expires_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    field :family_id, :string

    belongs_to :client, OauthClient, foreign_key: :oauth_client_id
    belongs_to :user, User
    belongs_to :access_token, OauthAccessToken

    timestamps()
  end

  def create_changeset(%__MODULE__{} = token, attrs) do
    token
    |> cast(attrs, [:selector, :verifier_hash, :expires_at])
    |> validate_required([
      :selector,
      :verifier_hash,
      :expires_at,
      :oauth_client_id,
      :user_id,
      :access_token_id,
      :family_id
    ])
    |> unique_constraint(:selector)
  end

  def revoke_changeset(token, revoked_at) do
    token
    |> cast(%{revoked_at: revoked_at}, [:revoked_at])
    |> validate_required([:revoked_at])
  end
end
