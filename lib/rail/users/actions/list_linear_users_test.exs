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
end
