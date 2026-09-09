defmodule Rail.Users do
  @moduledoc false

  alias Rail.Users.Actions

  defdelegate register_oauth_user(attrs), to: Actions.RegisterOAuthUser
  defdelegate get_user(id), to: Actions.GetUser
  defdelegate get_user!(id), to: Actions.GetUser
  defdelegate get_user_by_session_token(token), to: Actions.GetUserBySessionToken
  defdelegate generate_user_session_token(user), to: Actions.GenerateUserSessionToken
  defdelegate delete_user_session_token(token), to: Actions.DeleteUserSessionToken
  defdelegate list_users(scope), to: Actions.ListUsers
  defdelegate set_admin(scope, user, admin_bool), to: Actions.SetAdmin
  defdelegate set_project_filter(scope, project_id), to: Actions.SetProjectFilter
  defdelegate link_linear(scope_or_user, attrs), to: Actions.LinkLinear
  defdelegate unlink_linear(scope_or_user), to: Actions.UnlinkLinear
  defdelegate linear_token(scope_or_user), to: Actions.LinearToken
  defdelegate linear_token(scope_or_user, opts), to: Actions.LinearToken
  defdelegate can?(scope, action), to: Actions.Can
  defdelegate can?(scope, resource, action), to: Actions.Can
end
