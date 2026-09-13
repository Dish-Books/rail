defmodule Rail.Users.Actions.ListUsersTest do
  use Rail.DataCase, async: true

  alias Rail.Scope
  alias Rail.Users
  alias Rail.Users.Schemas.User

  test "admin scope can list users" do
    assert {:ok, %User{id: admin_id} = admin_user} =
             Users.register_oauth_user(%{
               github_id: "list_admin_gh",
               login: "list_admin",
               name: "Admin Alice",
               email: "admin_alice@example.com",
               admin: true
             })

    assert {:ok, %User{id: member_id}} =
             Users.register_oauth_user(%{
               github_id: "list_member_gh",
               login: "list_member",
               name: "Member Bob",
               email: "member_bob@example.com"
             })

    scope = Scope.for_user(admin_user)

    assert {:ok, [%User{id: ^admin_id}, %User{id: ^member_id}]} = Users.list_users(scope)
  end

  test "non-admin scope is not authorized to list users" do
    assert {:ok, _admin} =
             Users.register_oauth_user(%{
               github_id: "first_gh_list",
               login: "first_list",
               email: "first_list@example.com"
             })

    assert {:ok, non_admin_user} =
             Users.register_oauth_user(%{
               github_id: "non_admin_gh_list",
               login: "non_admin_list",
               email: "nonadminlist@example.com"
             })

    scope = Scope.for_user(non_admin_user)

    assert {:error, :not_authorized} = Users.list_users(scope)
  end

  test "system scope can list users" do
    assert {:ok, _user} =
             Users.register_oauth_user(%{
               github_id: "system_list_gh",
               login: "system_list",
               email: "systemlist@example.com"
             })

    assert {:ok, [%User{}]} = Users.list_users(Scope.for_system())
  end
end
