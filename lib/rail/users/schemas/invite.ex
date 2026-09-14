defmodule Rail.Users.Schemas.Invite do
  @moduledoc """
  A standing permission for one email address to become a user.

  GitHub will vouch for any account on the internet, so the invite — not the OAuth
  handshake — is what decides who gets in. `email` is the join key: the address on
  the invite has to match the address GitHub reports at sign-up.
  """
  use Rail.Schema

  alias Rail.Users.Schemas.User

  @primary_key {:id, UXID, autogenerate: true, prefix: "inv"}
  schema "invites" do
    field :email, :string
    field :admin, :boolean, default: false
    field :accepted_at, :utc_datetime_usec

    belongs_to :invited_by, User
    belongs_to :accepted_user, User

    timestamps()
  end

  @updatable_fields [:email, :admin, :accepted_at, :invited_by_id, :accepted_user_id]

  def changeset(invite, attrs) do
    invite
    |> cast(attrs, @updatable_fields)
    |> update_change(:email, &String.trim/1)
    |> validate_required([:email])
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, message: "must be a valid email address")
    |> unique_constraint(:email)
  end
end
