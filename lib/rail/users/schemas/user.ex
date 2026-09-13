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
    field :last_project_filter, :string

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
    :last_project_filter
  ]

  def changeset(user, attrs) do
    user
    |> cast(attrs, @updatable_fields)
    |> validate_required([:github_id, :login, :email])
    |> unique_constraint(:github_id)
    |> unique_constraint(:login)
    |> unique_constraint(:email)
  end
end
