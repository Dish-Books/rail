defmodule Rail.Users.Actions.UnlinkSlackTest do
  use Rail.DataCase, async: true

  alias Rail.Scope
  alias Rail.Users
  alias Rail.Users.Schemas.User

  test "forgets the person's Slack account" do
    unique = System.unique_integer([:positive])

    {:ok, user} =
      Users.register_oauth_user(%{github_id: "us_#{unique}", login: "us_#{unique}", email: "us_#{unique}@example.com"})

    {:ok, user} =
      Users.update_user(system_scope(), user, %{
        slack_user_id: "U1",
        slack_team_id: "T1",
        slack_name: "Priya",
        slack_access_token: "xoxp-1"
      })

    assert {:ok, %User{slack_user_id: nil, slack_team_id: nil, slack_name: nil, slack_access_token: nil}} =
             Users.unlink_slack(Scope.for_user(user))
  end

  test "needs a signed-in user" do
    assert {:error, :not_authenticated} = Users.unlink_slack(Scope.for_system())
  end
end
