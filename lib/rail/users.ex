defmodule Rail.Users do
  @moduledoc false

  use Rail.PermissionsDecorator

  alias Rail.Users.Actions

  defdelegate register_oauth_user(attrs), to: Actions.RegisterOAuthUser
  defdelegate sign_in_oauth_user(auth), to: Actions.SignInOAuthUser
  defdelegate get_user_by_session_token(token), to: Actions.GetUserBySessionToken
  defdelegate generate_user_session_token(user), to: Actions.GenerateUserSessionToken
  defdelegate delete_user_session_token(token), to: Actions.DeleteUserSessionToken

  @decorate can?(resource: :users, action: :list)
  defdelegate list_users(scope), to: Actions.ListUsers

  defdelegate get_user(by), to: Actions.GetUser
  defdelegate list_linear_users(), to: Actions.ListLinearUsers

  @decorate can?(resource: :users, action: :manage)
  defdelegate update_user(scope, user, attrs), to: Actions.UpdateUser

  @decorate can?(resource: :users, action: :list)
  defdelegate list_invites(scope), to: Actions.ListInvites

  @decorate can?(resource: :users, action: :manage)
  defdelegate invite_user(scope, attrs), to: Actions.InviteUser

  @decorate can?(resource: :users, action: :manage)
  defdelegate revoke_invite(scope, invite_id), to: Actions.RevokeInvite

  defdelegate create_signing_key(scope), to: Actions.CreateSigningKey
  defdelegate delete_signing_key(scope), to: Actions.DeleteSigningKey

  defdelegate linear_token(scope), to: Actions.LinearToken
  defdelegate link_linear(scope, code), to: Actions.LinkLinear
  defdelegate unlink_linear(scope), to: Actions.UnlinkLinear

  defdelegate slack_token(scope), to: Actions.SlackToken
  defdelegate link_slack(scope, code), to: Actions.LinkSlack
  defdelegate unlink_slack(scope), to: Actions.UnlinkSlack

  defdelegate can?(scope, action), to: Actions.Can
  defdelegate can?(scope, resource, action), to: Actions.Can
end
