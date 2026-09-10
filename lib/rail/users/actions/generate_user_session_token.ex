defmodule Rail.Users.Actions.GenerateUserSessionToken do
  @moduledoc false

  alias Rail.Repo
  alias Rail.Users.Schemas.User
  alias Rail.Users.Schemas.UserToken

  def generate_user_session_token(%User{} = user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end
end
