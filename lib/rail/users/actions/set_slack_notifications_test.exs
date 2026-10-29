defmodule Rail.Users.Actions.SetSlackNotificationsTest do
  use Rail.DataCase, async: true

  alias Rail.Scope
  alias Rail.Users
  alias Rail.Users.Schemas.User

  setup do
    unique = System.unique_integer([:positive])

    {:ok, user} =
      Users.register_oauth_user(%{github_id: "ssn_#{unique}", login: "ssn_#{unique}", email: "ssn_#{unique}@example.com"})

    %{user: user}
  end

  test "turns notifications on and off for someone with Slack connected, returning them as saved", %{user: user} do
    {:ok, linked} = Users.update_user(system_scope(), user, %{slack_user_id: "U1", slack_team_id: "T1"})

    assert {:ok, %User{slack_notifications: true}} = Users.set_slack_notifications(Scope.for_user(linked), true)
    assert %User{slack_notifications: true} = Repo.reload!(user)

    assert {:ok, %User{slack_notifications: false}} = Users.set_slack_notifications(Scope.for_user(linked), false)
    assert %User{slack_notifications: false} = Repo.reload!(user)
  end

  test "reads the user fresh, so a scope from before the link can turn them on", %{user: user} do
    {:ok, _linked} = Users.update_user(system_scope(), user, %{slack_user_id: "U1", slack_team_id: "T1"})

    assert {:ok, %User{slack_notifications: true, slack_user_id: "U1"}} =
             Users.set_slack_notifications(Scope.for_user(user), true)
  end

  test "refuses to turn them on without Slack connected", %{user: user} do
    assert {:error, changeset} = Users.set_slack_notifications(Scope.for_user(user), true)
    assert %{slack_notifications: ["connect Slack first"]} = errors_on(changeset)
    assert %User{slack_notifications: false} = Repo.reload!(user)
  end

  test "needs a signed-in user" do
    assert {:error, :not_authenticated} = Users.set_slack_notifications(Scope.for_system(), true)
  end
end
