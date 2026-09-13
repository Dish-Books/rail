defmodule Rail.Users.Actions.DeleteUserSessionToken do
  @moduledoc false

  import Ecto.Query

  alias Rail.Repo
  alias Rail.Users.Schemas.UserToken

  def delete_user_session_token(token) when is_binary(token) do
    hashed = :crypto.hash(:sha256, token)
    Repo.delete_all(from(UserToken, where: [token: ^hashed, context: "session"]))
    :ok
  end
end
