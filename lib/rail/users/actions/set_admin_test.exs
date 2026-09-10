defmodule Rail.Users.Actions.SetAdminTest do
  use Rail.DataCase, async: true

  alias Rail.Scope
  alias Rail.Users
  alias Rail.Users.Schemas.User

  test "admin can grant admin status to another user" do
    assert {:ok, admin_user} =
             Users.register_oauth_user(%{
               github_id: "admin_grant_gh",
               login: "admin_grant",
               email: "admingrant@example.com"
             })

    assert {:ok, %User{id: member_id} = member} =
             Users.register_oauth_user(%{
               github_id: "member_grant_gh",
               login: "member_grant",
               email: "membergrant@example.com"
             })

    scope = Scope.for_user(admin_user)

    assert {:ok, %User{id: ^member_id, admin: true}} = Users.set_admin(scope, member, true)
  end

  test "admin can accept user_id string" do
    assert {:ok, admin_user} =
             Users.register_oauth_user(%{
               github_id: "admin_str_gh",
               login: "admin_str",
               email: "adminstr@example.com"
             })

    assert {:ok, %User{id: member_id}} =
             Users.register_oauth_user(%{
               github_id: "member_str_gh",
               login: "member_str",
               email: "memberstr@example.com"
             })

    scope = Scope.for_user(admin_user)

    assert {:ok, %User{id: ^member_id, admin: true}} = Users.set_admin(scope, member_id, true)
  end

  test "cannot remove admin from oneself when sole admin" do
    assert {:ok, sole_admin} =
             Users.register_oauth_user(%{
               github_id: "sole_admin_gh",
               login: "sole_admin",
               email: "soleadmin@example.com"
             })

    scope = Scope.for_user(sole_admin)

    assert {:error, :cannot_remove_sole_admin} = Users.set_admin(scope, sole_admin, false)
  end

  test "can remove admin from oneself when another admin exists" do
    assert {:ok, admin1} =
             Users.register_oauth_user(%{
               github_id: "multi_admin_1_gh",
               login: "multi_admin_1",
               email: "multiadmin1@example.com"
             })

    assert {:ok, member} =
             Users.register_oauth_user(%{
               github_id: "multi_admin_2_gh",
               login: "multi_admin_2",
               email: "multiadmin2@example.com"
             })

    scope1 = Scope.for_user(admin1)
    assert {:ok, admin2} = Users.set_admin(scope1, member, true)

    # Now there are 2 admins: admin1 and admin2
    # admin1 can remove their own admin
    assert {:ok, %User{admin: false}} = Users.set_admin(scope1, admin1, false)

    # admin2 is now the sole admin and cannot remove admin from self
    scope2 = Scope.for_user(admin2)
    assert {:error, :cannot_remove_sole_admin} = Users.set_admin(scope2, admin2, false)
  end

  test "non-admin cannot change admin status" do
    assert {:ok, _admin} =
             Users.register_oauth_user(%{
               github_id: "admin_chk_gh",
               login: "admin_chk",
               email: "adminchk@example.com"
             })

    assert {:ok, member} =
             Users.register_oauth_user(%{
               github_id: "member_chk_gh",
               login: "member_chk",
               email: "memberchk@example.com"
             })

    scope = Scope.for_user(member)

    assert {:error, :not_authorized} = Users.set_admin(scope, member, true)
  end

  test "system scope can set admin status" do
    assert {:ok, admin_user} =
             Users.register_oauth_user(%{
               github_id: "admin_sys_gh",
               login: "admin_sys",
               email: "adminsys@example.com"
             })

    assert {:ok, member} =
             Users.register_oauth_user(%{
               github_id: "member_sys_gh",
               login: "member_sys",
               email: "membersys@example.com"
             })

    assert {:ok, %User{admin: true}} = Users.set_admin(Scope.for_system(), member, true)
    assert {:ok, %User{admin: false}} = Users.set_admin(Scope.for_system(), admin_user, false)
  end
end
