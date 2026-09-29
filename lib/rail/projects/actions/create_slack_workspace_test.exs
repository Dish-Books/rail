defmodule Rail.Projects.Actions.CreateSlackWorkspaceTest do
  use Rail.DataCase, async: true

  alias Rail.Projects
  alias Rail.Projects.Schemas.SlackWorkspace
  alias Rail.Slack

  setup do
    %{team_id: "T#{System.unique_integer([:positive])}"}
  end

  test "fills the workspace's ids from Slack and announces it", %{team_id: team_id} do
    Phoenix.PubSub.subscribe(Rail.PubSub, "slack_workspaces")

    Req.Test.expect(Slack, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer xoxb-new"]
      Req.Test.json(conn, %{"ok" => true, "team_id" => team_id, "bot_id" => "B_RAIL", "user_id" => "U_RAIL"})
    end)

    assert {:ok, %SlackWorkspace{id: id, external_id: ^team_id, bot_id: "B_RAIL", bot_user_id: "U_RAIL"}} =
             Projects.create_slack_workspace(system_scope(), %{
               "name" => "Acme",
               "token" => "xoxb-new",
               "app_token" => "xapp-new"
             })

    assert_receive {:slack_workspace_changed, ^id}
  end

  test "a token Slack refuses saves nothing" do
    Req.Test.expect(Slack, &Req.Test.json(&1, %{"ok" => false, "error" => "invalid_auth"}))

    assert {:error, changeset} =
             Projects.create_slack_workspace(system_scope(), %{"name" => "Acme", "token" => "xoxb-bad"})

    assert %{token: ["was refused by Slack (invalid_auth)"]} = errors_on(changeset)
  end

  test "a Slack that cannot be reached saves nothing" do
    Req.Test.expect(Slack, &Req.Test.transport_error(&1, :econnrefused))

    assert {:error, changeset} =
             Projects.create_slack_workspace(system_scope(), %{"name" => "Acme", "token" => "xoxb-new"})

    assert %{token: ["could not be checked with Slack"]} = errors_on(changeset)
  end

  test "a form missing its token never asks Slack" do
    assert {:error, changeset} = Projects.create_slack_workspace(system_scope(), %{"name" => "Acme"})
    assert %{token: ["can't be blank"]} = errors_on(changeset)
  end

  test "is for admins only" do
    assert {:error, :not_authorized} =
             Projects.create_slack_workspace(user_scope(), %{"name" => "Acme", "token" => "xoxb-new"})
  end
end
