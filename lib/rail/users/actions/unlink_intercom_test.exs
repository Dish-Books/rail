defmodule Rail.Users.Actions.UnlinkIntercomTest do
  use Rail.DataCase, async: true

  alias Rail.Scope
  alias Rail.Users
  alias Rail.Users.Schemas.User

  test "forgets the person's Intercom account and tells other pages" do
    unique = System.unique_integer([:positive])

    {:ok, user} =
      Users.register_oauth_user(%{github_id: "ui_#{unique}", login: "ui_#{unique}", email: "ui_#{unique}@example.com"})

    {:ok, %{id: user_id} = user} =
      Users.update_user(system_scope(), user, %{
        intercom_admin_id: "991",
        intercom_app_id: "app1",
        intercom_name: "Dana",
        intercom_access_token: "dana-token"
      })

    Phoenix.PubSub.subscribe(Rail.PubSub, "users")

    assert {:ok,
            %User{intercom_admin_id: nil, intercom_app_id: nil, intercom_name: nil, intercom_access_token: nil} = unlinked} =
             Users.unlink_intercom(Scope.for_user(user))

    refute Scope.intercom_linked?(Scope.for_user(unlinked))
    assert_receive {:users_changed, ^user_id}
  end

  test "needs a signed-in user" do
    assert {:error, :not_authenticated} = Users.unlink_intercom(Scope.for_system())
  end
end
