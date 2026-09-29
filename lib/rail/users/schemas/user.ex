defmodule Rail.Users.Schemas.User do
  @moduledoc false
  use Rail.Schema

  alias Rail.Types.EncryptedBinary

  @primary_key {:id, UXID, autogenerate: true, prefix: "usr"}
  schema "users" do
    field :github_id, :string
    field :login, :string
    field :name, :string
    field :email, :string
    field :avatar_url, :string
    field :admin, :boolean, default: false
    field :github_token, EncryptedBinary, redact: true
    field :linear_user_id, :string
    field :linear_name, :string
    field :linear_access_token, EncryptedBinary, redact: true
    field :linear_refresh_token, EncryptedBinary, redact: true
    field :linear_token_expires_at, :utc_datetime_usec
    field :slack_user_id, :string
    field :slack_team_id, :string
    field :slack_name, :string
    field :slack_access_token, EncryptedBinary, redact: true
    field :signing_key, EncryptedBinary, redact: true
    field :signing_public_key, :string
    field :signing_key_github_id, :integer

    has_many :tokens, Rail.Users.Schemas.UserToken, on_delete: :delete_all

    timestamps()
  end

  @updatable_fields [
    :github_id,
    :login,
    :name,
    :email,
    :avatar_url,
    :admin,
    :github_token,
    :linear_user_id,
    :linear_name,
    :linear_access_token,
    :linear_refresh_token,
    :linear_token_expires_at,
    :slack_user_id,
    :slack_team_id,
    :slack_name,
    :slack_access_token,
    :signing_key,
    :signing_public_key,
    :signing_key_github_id
  ]

  def changeset(user, attrs) do
    user
    |> cast(attrs, @updatable_fields)
    |> validate_required([:github_id, :login, :email])
    |> unique_constraint(:github_id)
    |> unique_constraint(:login)
    |> unique_constraint(:email)
  end

  @doc """
  True when this user has a signing key Rail can commit with.
  """
  def signing?(%__MODULE__{signing_key: key}) when is_binary(key), do: true
  def signing?(%__MODULE__{}), do: false

  @doc """
  The signing key's fingerprint, as GitHub shows it, or nil when there is none.

  The public key is stored as an OpenSSH `ssh-ed25519 <base64> <comment>`
  line, so the fingerprint is the sha256 of the decoded blob.
  """
  def signing_fingerprint(%__MODULE__{signing_public_key: line}) when is_binary(line) do
    case String.split(line, " ") do
      [_type, blob | _comment] ->
        digest = :sha256 |> :crypto.hash(Base.decode64!(blob)) |> Base.encode64(padding: false)
        "SHA256:" <> digest

      _malformed ->
        nil
    end
  end

  def signing_fingerprint(%__MODULE__{}), do: nil
end
