defmodule Rail.Users.Actions.UnlinkLinearTest do
  use Rail.DataCase, async: true

  alias Rail.Scope
  alias Rail.Users
  alias Rail.Users.Schemas.User

  setup do
    id = System.unique_integer([:positive])

    assert {:ok, %User{id: user_id} = user} =
             Users.register_oauth_user(%{
               github_id: "unlink_gh_#{id}",
               login: "unlink_user_#{id}",
               email: "unlink_#{id}@example.com"
             })

    attrs = %{
      linear_user_id: "lin_usr_#{id}",
      linear_name: "Linear User #{id}",
      linear_access_token: "lin_at_#{id}",
      linear_refresh_token: "lin_rt_#{id}",
      expires_in: 3600
    }

    assert {:ok, %User{} = linked_user} = Users.link_linear(user, attrs)

    %{user: linked_user, user_id: user_id, scope: Scope.for_user(linked_user)}
  end

  test "unlinks linear with user scope", %{scope: scope, user_id: user_id} do
    assert {:ok,
            %User{
              id: ^user_id,
              linear_user_id: nil,
              linear_name: nil,
              linear_access_token: nil,
              linear_refresh_token: nil,
              linear_token_expires_at: nil
            }} = Users.unlink_linear(scope)

    reloaded = Repo.get!(User, user_id)
    assert is_nil(reloaded.linear_access_token)
    assert is_nil(reloaded.linear_refresh_token)
    assert is_nil(reloaded.linear_user_id)
    assert is_nil(reloaded.linear_name)
    assert is_nil(reloaded.linear_token_expires_at)
  end

  test "unlinks linear with map-user scope", %{user_id: user_id} do
    scope = %Scope{user: %{id: user_id}}

    assert {:ok, %User{id: ^user_id, linear_access_token: nil}} =
             Users.unlink_linear(scope)
  end

  test "unlinks linear with User struct directly", %{user: user, user_id: user_id} do
    assert {:ok, %User{id: ^user_id, linear_access_token: nil}} =
             Users.unlink_linear(user)
  end

  test "unlinks linear with user ID string directly", %{user_id: user_id} do
    assert {:ok, %User{id: ^user_id, linear_access_token: nil}} =
             Users.unlink_linear(user_id)
  end

  test "returns not_found when user does not exist" do
    assert {:error, :not_found} = Users.unlink_linear("usr_nonexistent99999")
  end

  test "returns not_authorized when scope is invalid" do
    assert {:error, :not_authorized} = Users.unlink_linear(nil)
    assert {:error, :not_authorized} = Users.unlink_linear(%Scope{user: nil})
  end
end
