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

  def oauth_changeset(user, attrs) do
    user
    |> cast(attrs, [:github_id, :login, :name, :email, :avatar_url, :github_token, :admin])
    |> validate_required([:github_id, :login, :email])
    |> unique_constraint(:github_id)
    |> unique_constraint(:login)
    |> unique_constraint(:email)
  end

  def admin_changeset(user, attrs) do
    user
    |> cast(attrs, [:admin])
    |> validate_required([:admin])
  end

  def project_filter_changeset(user, attrs) do
    cast(user, attrs, [:last_project_filter])
  end

  def linear_link_changeset(user, attrs) do
    user
    |> cast(attrs, [
      :linear_user_id,
      :linear_name,
      :linear_access_token,
      :linear_refresh_token,
      :linear_token_expires_at
    ])
    |> validate_required([:linear_access_token, :linear_refresh_token, :linear_token_expires_at])
  end

  def linear_unlink_changeset(user) do
    change(user, %{
      linear_user_id: nil,
      linear_name: nil,
      linear_access_token: nil,
      linear_refresh_token: nil,
      linear_token_expires_at: nil
    })
  end

  def factory do
    id = System.unique_integer([:positive])

    %__MODULE__{
      github_id: "#{id}",
      login: "user#{id}",
      name: "User #{id}",
      email: "user#{id}@example.com",
      avatar_url: "https://avatars.githubusercontent.com/u/#{id}",
      admin: false,
      github_token: "gho_token_#{id}"
    }
  end
end
