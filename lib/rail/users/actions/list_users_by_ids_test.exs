defmodule Rail.Users.Actions.ListUsersByIdsTest do
  use Rail.DataCase, async: true

  alias Rail.Users
  alias Rail.Users.Schemas.User

  test "anyone signed in sees who the ids belong to, and nobody else" do
    {:ok, %User{id: dana_id}} =
      Users.register_oauth_user(%{github_id: "ids_dana_gh", login: "dana", name: "Dana Reyes", email: "dana@example.com"})

    {:ok, %User{}} =
      Users.register_oauth_user(%{github_id: "ids_omar_gh", login: "omar", email: "omar@example.com"})

    {:ok, reader} =
      Users.register_oauth_user(%{github_id: "ids_reader_gh", login: "reader", email: "reader@example.com"})

    assert [%User{id: ^dana_id, name: "Dana Reyes"}] =
             Users.list_users_by_ids(user_scope(user: reader), [dana_id, "usr_gone"])
  end
end
