defmodule Rail.Users.Actions.UnlinkLinearTest do
  use Rail.DataCase, async: true

  alias Rail.Scope
  alias Rail.Users
  alias Rail.Users.Schemas.User

  test "forgets the scope's user's Linear account and tokens" do
    {:ok, user} =
      Users.register_oauth_user(%{github_id: "gh_unlink_linear", login: "unlink_linear", email: "unlink@example.com"})

    {:ok, user} =
      Users.update_user(Scope.for_system(), user, %{
        linear_user_id: "lin_usr_unlink",
        linear_name: "Unlink Me",
        linear_access_token: "lin_at_unlink",
        linear_refresh_token: "lin_rt_unlink",
        linear_token_expires_at: DateTime.utc_now()
      })

    assert {:ok,
            %User{
              linear_user_id: nil,
              linear_name: nil,
              linear_access_token: nil,
              linear_refresh_token: nil,
              linear_token_expires_at: nil
            }} = Users.unlink_linear(Scope.for_user(user))
  end

  test "needs a signed-in user" do
    assert {:error, :not_authenticated} = Users.unlink_linear(Scope.for_system())
  end
end
