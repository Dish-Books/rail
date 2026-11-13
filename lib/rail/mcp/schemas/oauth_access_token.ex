defmodule Rail.Mcp.Schemas.OauthAccessToken do
  @moduledoc """
  An hour's bearer token for `/mcp`, acting as its user. Every token one consent produced shares its `family_id`.
  """
  use Rail.Schema

  alias Rail.Mcp.Schemas.OauthClient
  alias Rail.Users.Schemas.User

  @primary_key {:id, UXID, autogenerate: true, prefix: "oat"}
  schema "oauth_access_tokens" do
    field :selector, :string
    field :verifier_hash, :binary, redact: true
    field :expires_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    # Written by the plug at most once a minute, through `update_all`, so `updated_at` stays the token's last change.
    field :last_used_at, :utc_datetime_usec
    field :family_id, :string

    belongs_to :client, OauthClient, foreign_key: :oauth_client_id
    belongs_to :user, User

    timestamps()
  end

  def create_changeset(%__MODULE__{} = token, attrs) do
    token
    |> cast(attrs, [:selector, :verifier_hash, :expires_at])
    |> validate_required([:selector, :verifier_hash, :expires_at, :oauth_client_id, :user_id, :family_id])
    |> unique_constraint(:selector)
  end

  def revoke_changeset(token, revoked_at) do
    token
    |> cast(%{revoked_at: revoked_at}, [:revoked_at])
    |> validate_required([:revoked_at])
  end
end
