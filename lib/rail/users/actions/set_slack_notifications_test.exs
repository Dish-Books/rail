defmodule Rail.Users.Actions.SetSlackNotificationsTest do
  use Rail.DataCase, async: true

  alias Rail.Projects
  alias Rail.Scope
  alias Rail.Slack
  alias Rail.Users
  alias Rail.Users.Schemas.User

  setup {Req.Test, :verify_on_exit!}

  setup do
    unique = System.unique_integer([:positive])
    team_id = "T#{unique}"

    {:ok, user} =
      Users.register_oauth_user(%{github_id: "ssn_#{unique}", login: "ssn_#{unique}", email: "ssn_#{unique}@example.com"})

    Req.Test.expect(Slack, &Req.Test.json(&1, %{"ok" => true, "team_id" => team_id}))
    {:ok, _workspace} = Projects.create_slack_workspace(system_scope(), %{"name" => "Acme", "token" => "xoxb-ssn"})

    %{user: user, team_id: team_id}
  end

  test "turning on sends the first message to the user's Slack id on the bot token, then saves On", %{
    user: user,
    team_id: team_id
  } do
    {:ok, linked} = Users.update_user(system_scope(), user, %{slack_user_id: "U1", slack_team_id: team_id})
    Phoenix.PubSub.subscribe(Rail.PubSub, "users")
    test_pid = self()

    Req.Test.expect(Slack, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert "/api/chat.postMessage" = conn.request_path
      assert ["Bearer xoxb-ssn"] = Plug.Conn.get_req_header(conn, "authorization")
      send(test_pid, {:posted, Jason.decode!(body)})
      Req.Test.json(conn, %{"ok" => true, "ts" => "1790000000.000100"})
    end)

    assert {:ok, %User{id: user_id, slack_notifications: true}} =
             Users.set_slack_notifications(Scope.for_user(linked), true)

    assert_received {:posted,
                     %{
                       "channel" => "U1",
                       "text" =>
                         "Rail will message you here when a task you own waits on you, and when someone else merges it."
                     }}

    assert_received {:users_changed, ^user_id}
    assert %User{slack_notifications: true} = Repo.reload!(user)
  end

  test "turning off sends nothing to Slack and saves Off", %{user: user, team_id: team_id} do
    {:ok, linked} = Users.update_user(system_scope(), user, %{slack_user_id: "U1", slack_team_id: team_id})
    {:ok, _on} = linked |> User.slack_notifications_changeset(%{slack_notifications: true}) |> Repo.update()
    Phoenix.PubSub.subscribe(Rail.PubSub, "users")

    assert {:ok, %User{id: user_id, slack_notifications: false}} =
             Users.set_slack_notifications(Scope.for_user(linked), false)

    assert_received {:users_changed, ^user_id}
    assert %User{slack_notifications: false} = Repo.reload!(user)
  end

  test "turning on what is already on sends no second message", %{user: user, team_id: team_id} do
    {:ok, linked} = Users.update_user(system_scope(), user, %{slack_user_id: "U1", slack_team_id: team_id})
    {:ok, _on} = linked |> User.slack_notifications_changeset(%{slack_notifications: true}) |> Repo.update()

    assert {:ok, %User{slack_notifications: true}} = Users.set_slack_notifications(Scope.for_user(linked), true)
  end

  test "a refused first message returns Slack's error and leaves notifications off", %{
    user: user,
    team_id: team_id
  } do
    {:ok, linked} = Users.update_user(system_scope(), user, %{slack_user_id: "U1", slack_team_id: team_id})
    Req.Test.expect(Slack, &Req.Test.json(&1, %{"ok" => false, "error" => "messages_tab_disabled"}))

    assert {:error, {:slack_error, "messages_tab_disabled"}} =
             Users.set_slack_notifications(Scope.for_user(linked), true)

    assert %User{slack_notifications: false} = Repo.reload!(user)
  end

  test "a Slack id with no team is not found and stays off", %{user: user} do
    {:ok, linked} = Users.update_user(system_scope(), user, %{slack_user_id: "U1"})

    assert {:error, :not_found} = Users.set_slack_notifications(Scope.for_user(linked), true)
    assert %User{slack_notifications: false} = Repo.reload!(user)
  end

  test "a team Rail has no workspace for is not found and stays off", %{user: user} do
    {:ok, linked} = Users.update_user(system_scope(), user, %{slack_user_id: "U1", slack_team_id: "T_ELSEWHERE"})

    assert {:error, :not_found} = Users.set_slack_notifications(Scope.for_user(linked), true)
    assert %User{slack_notifications: false} = Repo.reload!(user)
  end

  test "reads the user fresh, so a scope from before the link can turn them on", %{user: user, team_id: team_id} do
    {:ok, _linked} = Users.update_user(system_scope(), user, %{slack_user_id: "U1", slack_team_id: team_id})
    Req.Test.expect(Slack, &Req.Test.json(&1, %{"ok" => true, "ts" => "1790000000.000100"}))

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
