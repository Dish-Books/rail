defmodule Rail.Users.Schemas.UserToken do
  @moduledoc false
  use Rail.Schema

  alias Rail.Users.Schemas.User

  @rand_size 32
  @session_validity_in_days 30

  @primary_key {:id, UXID, autogenerate: true, prefix: "tok"}
  schema "users_tokens" do
    field :token, :binary
    field :context, :string
    field :sent_to, :string

    belongs_to :user, User

    timestamps(updated_at: false)
  end

  def session_validity_in_days, do: @session_validity_in_days

  @doc """
  Builds a session token, returning the raw token for the client and a struct
  holding only its SHA-256 digest. The digest is what lands in the database, so
  read access to `users_tokens` yields no usable session credentials.
  """
  def build_session_token(%User{} = user) do
    token = :crypto.strong_rand_bytes(@rand_size)
    {token, %__MODULE__{token: :crypto.hash(:sha256, token), context: "session", user_id: user.id}}
  end
end
