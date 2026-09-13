defmodule Rail.Users do
  @moduledoc false

  use Rail.PermissionsDecorator

  alias Rail.Users.Actions

  defdelegate register_oauth_user(attrs), to: Actions.RegisterOAuthUser
  defdelegate get_user_by_session_token(token), to: Actions.GetUserBySessionToken
  defdelegate generate_user_session_token(user), to: Actions.GenerateUserSessionToken
  defdelegate delete_user_session_token(token), to: Actions.DeleteUserSessionToken

  @decorate can?(resource: :users, action: :list)
  defdelegate list_users(scope), to: Actions.ListUsers

  defdelegate get_user(by), to: Actions.GetUser

  @decorate can?(resource: :users, action: :manage)
  defdelegate update_user(scope, user, attrs), to: Actions.UpdateUser

  defdelegate linear_token(scope_or_user), to: Actions.LinearToken

  defdelegate can?(scope, action), to: Actions.Can
  defdelegate can?(scope, resource, action), to: Actions.Can
end
