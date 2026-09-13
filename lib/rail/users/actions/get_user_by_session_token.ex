defmodule Rail.Users.Actions.GetUserBySessionToken do
  @moduledoc false

  import Ecto.Query

  alias Rail.Repo
  alias Rail.Users.Schemas.UserToken

  def get_user_by_session_token(token) when is_binary(token) do
    hashed = :crypto.hash(:sha256, token)
    cutoff = DateTime.shift(DateTime.utc_now(), day: -UserToken.session_validity_in_days())

    query =
      from t in UserToken,
        join: user in assoc(t, :user),
        where: t.token == ^hashed and t.context == "session",
        where: t.inserted_at > ^cutoff,
        select: {user, t.inserted_at}

    Repo.one(query)
  end

  def get_user_by_session_token(_token), do: nil
end
