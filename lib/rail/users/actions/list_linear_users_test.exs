defmodule Rail.Users.Actions.ListLinearUsersTest do
  use Rail.DataCase, async: true

  alias Rail.Repo
  alias Rail.Users
  alias Rail.Users.Schemas.User

  test "list_linear_users/0 lists only the users with a linked Linear account" do
    {:ok, linked} =
      Users.register_oauth_user(%{github_id: "gh_linked", login: "linked", email: "linked@example.com"})

    {:ok, _unlinked} =
      Users.register_oauth_user(%{github_id: "gh_unlinked", login: "unlinked", email: "unlinked@example.com"})

    %User{id: linked_id} = linked |> Ecto.Changeset.change(linear_user_id: "lin_usr_linked") |> Repo.update!()

    assert [%User{id: ^linked_id}] = Users.list_linear_users()
  end

  test "with a project, lists only admins and the users granted that project" do
    linked = fn login, attrs ->
      {:ok, user} = Users.register_oauth_user(%{github_id: "gh_#{login}", login: login, email: "#{login}@example.com"})
      user |> Ecto.Changeset.change(Map.put(attrs, :linear_user_id, "lin_#{login}")) |> Repo.update!()
    end

    %User{id: granted_id} = linked.("granted", %{project_ids: ["prj_a"]})
    %User{id: admin_id} = linked.("admin", %{admin: true})
    %User{} = linked.("elsewhere", %{project_ids: ["prj_b"]})
    %User{} = linked.("nowhere", %{})

    assert Enum.sort([admin_id, granted_id]) ==
             [project_id: "prj_a"] |> Users.list_linear_users() |> Enum.map(& &1.id) |> Enum.sort()

    assert length(Users.list_linear_users()) == 4
  end
end
