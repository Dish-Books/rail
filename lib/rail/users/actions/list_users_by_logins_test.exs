defmodule Rail.Users.Actions.ListUsersByLoginsTest do
  use Rail.DataCase, async: true

  alias Rail.Users
  alias Rail.Users.Schemas.User

  test "returns the users whose logins are given and skips logins with no user" do
    id = System.unique_integer([:positive])

    {:ok, %User{id: dana_id}} =
      Users.register_oauth_user(%{github_id: "logins_dana_#{id}", login: "dana-#{id}", email: "dana-#{id}@example.com"})

    {:ok, %User{}} =
      Users.register_oauth_user(%{github_id: "logins_omar_#{id}", login: "omar-#{id}", email: "omar-#{id}@example.com"})

    assert [%User{id: ^dana_id}] = Users.list_users_by_logins(["dana-#{id}", "stranger-#{id}"])
    assert [] = Users.list_users_by_logins([])
  end
end
