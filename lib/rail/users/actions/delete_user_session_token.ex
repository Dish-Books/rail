defmodule Rail.Users.Actions.DeleteUserSessionToken do
  @moduledoc false

  import Ecto.Query

  alias Rail.Repo
  alias Rail.Users.Schemas.UserToken

  def delete_user_session_token(token) when is_binary(token) do
    Repo.delete_all(from(UserToken, where: [token: ^token, context: "session"]))
    :ok
  end
end
