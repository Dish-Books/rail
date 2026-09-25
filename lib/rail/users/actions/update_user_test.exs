defmodule Rail.Users.Actions.UpdateUserTest do
  use Rail.DataCase, async: true

  alias Rail.Scope
  alias Rail.Users
  alias Rail.Users.Schemas.User

  setup do
    id = System.unique_integer([:positive])

    assert {:ok, %User{id: user_id} = user} =
             Users.register_oauth_user(%{
               github_id: "upd_gh_#{id}",
               login: "upd_user_#{id}",
               email: "upd_#{id}@example.com"
             })

    assert {:ok, %User{} = admin} =
             Users.register_oauth_user(%{
               github_id: "upd_admin_gh_#{id}",
               login: "upd_admin_#{id}",
               email: "upd_admin_#{id}@example.com",
               admin: true
             })

    %{
      user: user,
      user_id: user_id,
      admin: admin,
      scope: Scope.for_user(user),
      admin_scope: Scope.for_user(admin)
    }
  end

  describe "profile fields" do
    test "rejects a non-admin, including on their own record", %{scope: scope, user: user, admin: admin} do
      assert {:error, :not_authorized} = Users.update_user(scope, admin, %{name: "Renamed"})
      assert {:error, :not_authorized} = Users.update_user(scope, user, %{name: "Renamed"})
    end

    test "an admin can update another user", %{admin_scope: scope, user: user} do
      assert {:ok, %User{name: "Renamed"}} = Users.update_user(scope, user, %{name: "Renamed"})
    end

    test "rejects a nil or user-less scope", %{user: user} do
      assert {:error, :not_authorized} = Users.update_user(nil, user, %{name: "X"})
      assert {:error, :not_authorized} = Users.update_user(%Scope{user: nil}, user, %{name: "X"})
    end
  end

  describe "admin flag" do
    test "an admin can grant admin status", %{admin_scope: scope, user: user, user_id: user_id} do
      assert {:ok, %User{id: ^user_id, admin: true}} = Users.update_user(scope, user, %{admin: true})
    end

    test "a non-admin cannot grant themselves admin", %{scope: scope, user: user} do
      assert {:error, :not_authorized} = Users.update_user(scope, user, %{admin: true})
    end

    test "an admin can rename another user", %{admin_scope: scope, user: user} do
      assert {:ok, %User{name: "Renamed"}} = Users.update_user(scope, user, %{name: "Renamed"})
    end

    test "the system scope can set admin status", %{user: user, admin: admin} do
      assert {:ok, %User{admin: true}} = Users.update_user(Scope.for_system(), user, %{admin: true})
      assert {:ok, %User{admin: false}} = Users.update_user(Scope.for_system(), admin, %{admin: false})
    end
  end

  describe "linear credentials" do
    test "links a Linear account", %{user: user, user_id: user_id} do
      scope = Scope.for_system()
      expires_at = DateTime.shift(DateTime.utc_now(), hour: 1)

      assert {:ok,
              %User{
                id: ^user_id,
                linear_user_id: "lin_usr",
                linear_name: "Linear User",
                linear_access_token: "lin_at",
                linear_refresh_token: "lin_rt",
                linear_token_expires_at: %DateTime{}
              }} =
               Users.update_user(scope, user, %{
                 linear_user_id: "lin_usr",
                 linear_name: "Linear User",
                 linear_access_token: "lin_at",
                 linear_refresh_token: "lin_rt",
                 linear_token_expires_at: expires_at
               })
    end

    test "unlinks a Linear account", %{user: user} do
      scope = Scope.for_system()

      assert {:ok, %User{} = linked} =
               Users.update_user(scope, user, %{
                 linear_user_id: "lin_usr",
                 linear_name: "Linear User",
                 linear_access_token: "lin_at",
                 linear_refresh_token: "lin_rt",
                 linear_token_expires_at: DateTime.shift(DateTime.utc_now(), hour: 1)
               })

      assert {:ok,
              %User{
                linear_user_id: nil,
                linear_name: nil,
                linear_access_token: nil,
                linear_refresh_token: nil,
                linear_token_expires_at: nil
              }} =
               Users.update_user(scope, linked, %{
                 linear_user_id: nil,
                 linear_name: nil,
                 linear_access_token: nil,
                 linear_refresh_token: nil,
                 linear_token_expires_at: nil
               })
    end

    test "keeps existing credentials when updating an unrelated field", %{user: user} do
      scope = Scope.for_system()

      assert {:ok, %User{} = linked} =
               Users.update_user(scope, user, %{
                 linear_access_token: "lin_at",
                 linear_refresh_token: "lin_rt",
                 linear_token_expires_at: DateTime.shift(DateTime.utc_now(), hour: 1)
               })

      assert {:ok, %User{linear_access_token: "lin_at", name: "Renamed"}} =
               Users.update_user(scope, linked, %{name: "Renamed"})
    end
  end
end
