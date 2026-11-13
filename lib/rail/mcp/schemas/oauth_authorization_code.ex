defmodule Rail.Mcp.Schemas.OauthAuthorizationCode do
  @moduledoc """
  The single-use code a person's consent issues, exchanged at `/oauth/token` for the first token pair of its family.
  """
  use Rail.Schema

  alias Rail.Mcp.Schemas.OauthClient
  alias Rail.Users.Schemas.User

  @primary_key {:id, UXID, autogenerate: true, prefix: "oacd"}
  schema "oauth_authorization_codes" do
    field :selector, :string
    field :verifier_hash, :binary, redact: true
    field :redirect_uri, :string
    field :expires_at, :utc_datetime_usec
    field :consumed_at, :utc_datetime_usec
    field :family_id, :string
    field :code_challenge, :string

    belongs_to :client, OauthClient, foreign_key: :oauth_client_id
    belongs_to :user, User

    timestamps()
  end

  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :selector,
      :verifier_hash,
      :family_id,
      :redirect_uri,
      :expires_at,
      :oauth_client_id,
      :user_id,
      :code_challenge
    ])
    |> validate_required([
      :selector,
      :verifier_hash,
      :family_id,
      :redirect_uri,
      :expires_at,
      :oauth_client_id,
      :user_id,
      :code_challenge
    ])
    |> unique_constraint(:selector)
    |> unique_constraint(:family_id)
  end

  def consume_changeset(code, consumed_at) do
    code
    |> cast(%{consumed_at: consumed_at}, [:consumed_at])
    |> validate_required([:consumed_at])
  end
end
