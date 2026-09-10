defmodule Rail.Users.Schemas.UserToken do
  @moduledoc false
  use Rail.Schema

  import Ecto.Query

  alias Rail.Users.Schemas.User

  @rand_size 32
  @session_validity_in_days 14

  @primary_key {:id, UXID, autogenerate: true, prefix: "tok"}
  schema "users_tokens" do
    field :token, :binary
    field :context, :string
    field :sent_to, :string

    belongs_to :user, User

    timestamps(updated_at: false)
  end

  def build_session_token(%User{} = user) do
    token = :crypto.strong_rand_bytes(@rand_size)
    {token, %__MODULE__{token: token, context: "session", user_id: user.id}}
  end

  def verify_session_token_query(token) when is_binary(token) do
    query =
      from token in by_token_and_context_query(token, "session"),
        join: user in assoc(token, :user),
        where: token.inserted_at > ago(@session_validity_in_days, "day"),
        select: {user, token.inserted_at}

    {:ok, query}
  end

  def by_token_and_context_query(token, context) when is_binary(token) and is_binary(context) do
    from __MODULE__, where: [token: ^token, context: ^context]
  end
end
