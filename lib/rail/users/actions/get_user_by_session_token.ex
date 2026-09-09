defmodule Rail.Users.Actions.GetUserBySessionToken do
  @moduledoc false

  alias Rail.Repo
  alias Rail.Users.Schemas.UserToken

  def get_user_by_session_token(token) when is_binary(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end

  def get_user_by_session_token(_token), do: nil
end
