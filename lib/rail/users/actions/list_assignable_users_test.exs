defmodule Rail.Users.Actions.ListAssignableUsersTest do
  use Rail.DataCase, async: true

  alias Rail.Repo
  alias Rail.Users
  alias Rail.Users.Schemas.User

  test "with a project, lists only admins and the users granted that project" do
    registered = fn login, attrs ->
      {:ok, user} =
        Users.register_oauth_user(%{
          github_id: "gh_#{login}_list-assignable-users",
          login: "#{login}-list-assignable-users",
          email: "#{login}-list-assignable-users@example.com"
        })

      user |> Ecto.Changeset.change(attrs) |> Repo.update!()
    end

    %User{id: granted_id} = registered.("granted", %{project_ids: ["prj_a"]})
    %User{id: admin_id} = registered.("admin", %{admin: true})
    %User{} = registered.("elsewhere", %{project_ids: ["prj_b"]})
    %User{} = registered.("nowhere", %{})

    assert Enum.sort([admin_id, granted_id]) ==
             [project_id: "prj_a"] |> Users.list_assignable_users() |> Enum.map(& &1.id) |> Enum.sort()

    assert length(Users.list_assignable_users()) == 4
  end

  test "lists everyone with GitHub" do
    {:ok, %User{id: user_id}} =
      Users.register_oauth_user(%{github_id: "gh_assignable", login: "assignable", email: "assignable@example.com"})

    assert user_id in Enum.map(Users.list_assignable_users(), & &1.id)
  end

  test "someone who disconnected GitHub is not assignable" do
    {:ok, user} =
      Users.register_oauth_user(%{github_id: "gh_assignable_gone", login: "assignable-gone", email: "ag@example.com"})

    {:ok, %User{id: user_id}} = Users.unlink_github(Rail.Scope.for_user(user))

    refute user_id in Enum.map(Users.list_assignable_users(), & &1.id)
  end

  test "a support person is not assignable, while a tester is" do
    register = fn login, role ->
      {:ok, user} =
        Users.register_oauth_user(%{
          github_id: "gh_#{login}_assignable_role",
          login: "#{login}-assignable-role",
          email: "#{login}-assignable-role@example.com"
        })

      {:ok, user} = Users.update_user(system_scope(), user, %{role: role})
      user
    end

    %User{id: support_id} = register.("support", :support)
    %User{id: tester_id} = register.("tester", :tester)

    ids = Enum.map(Users.list_assignable_users(), & &1.id)
    refute support_id in ids
    assert tester_id in ids
  end
end
