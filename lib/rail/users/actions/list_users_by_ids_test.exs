defmodule Rail.Users.Actions.ListUsersByIdsTest do
  use Rail.DataCase, async: true

  alias Rail.Users
  alias Rail.Users.Schemas.User

  test "anyone signed in sees who the ids belong to, and nobody else" do
    id = System.unique_integer([:positive])

    {:ok, %User{id: dana_id}} =
      Users.register_oauth_user(%{
        github_id: "ids_dana_gh-#{id}",
        login: "dana-#{id}",
        name: "Dana Reyes",
        email: "dana-#{id}@example.com"
      })

    {:ok, %User{}} =
      Users.register_oauth_user(%{github_id: "ids_omar_gh_#{id}", login: "omar-#{id}", email: "omar-#{id}@example.com"})

    {:ok, reader} =
      Users.register_oauth_user(%{
        github_id: "ids_reader_gh_#{id}",
        login: "reader-#{id}",
        email: "reader-#{id}@example.com"
      })

    assert [%User{id: ^dana_id, name: "Dana Reyes"}] =
             Users.list_users_by_ids(user_scope(user: reader), [dana_id, "usr_gone"])
  end
end
