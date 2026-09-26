defmodule Rail.Users.Actions.SlackTokenTest do
  use Rail.DataCase, async: true

  alias Rail.Scope
  alias Rail.Users

  setup do
    unique = System.unique_integer([:positive])

    {:ok, user} =
      Users.register_oauth_user(%{github_id: "st_#{unique}", login: "st_#{unique}", email: "st_#{unique}@example.com"})

    %{user: user}
  end

  test "returns the person's token with the workspace it is for", %{user: user} do
    {:ok, user} = Users.update_user(system_scope(), user, %{slack_team_id: "T1", slack_access_token: "xoxp-1"})

    assert {:ok, "xoxp-1", "T1"} = Users.slack_token(Scope.for_user(user))
  end

  test "an unlinked user has none", %{user: user} do
    assert {:error, :not_linked} = Users.slack_token(Scope.for_user(user))
    assert {:error, :not_linked} = Users.slack_token(Scope.for_system())
  end
end
