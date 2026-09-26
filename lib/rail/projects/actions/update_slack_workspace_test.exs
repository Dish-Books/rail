defmodule Rail.Projects.Actions.UpdateSlackWorkspaceTest do
  use Rail.DataCase, async: true

  alias Rail.Projects
  alias Rail.Projects.Schemas.SlackWorkspace
  alias Rail.Slack

  setup do
    team_id = "T#{System.unique_integer([:positive])}"
    Req.Test.expect(Slack, &Req.Test.json(&1, %{"ok" => true, "team_id" => team_id, "bot_id" => "B1"}))

    {:ok, workspace} =
      Projects.create_slack_workspace(system_scope(), %{"name" => "Acme", "token" => "xoxb-1", "app_token" => "xapp-1"})

    %{workspace: workspace}
  end

  test "blank secrets keep the saved ones, and the change is announced", %{workspace: %{id: id} = workspace} do
    Phoenix.PubSub.subscribe(Rail.PubSub, "slack_workspaces")

    assert {:ok, %SlackWorkspace{id: ^id, name: "Acme Inc", token: "xoxb-1", app_token: "xapp-1"}} =
             Projects.update_slack_workspace(system_scope(), workspace, %{
               "name" => "Acme Inc",
               "token" => "",
               "app_token" => ""
             })

    assert_receive {:slack_workspace_changed, ^id}
  end

  test "a new bot token is checked with Slack again", %{workspace: workspace} do
    Req.Test.expect(Slack, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer xoxb-2"]
      Req.Test.json(conn, %{"ok" => true, "team_id" => workspace.external_id, "bot_id" => "B2"})
    end)

    assert {:ok, %SlackWorkspace{token: "xoxb-2", bot_id: "B2"}} =
             Projects.update_slack_workspace(system_scope(), workspace, %{"token" => "xoxb-2"})
  end

  test "a new token Slack refuses, or a blank name, saves nothing", %{workspace: workspace} do
    Req.Test.expect(Slack, &Req.Test.json(&1, %{"ok" => false, "error" => "token_revoked"}))

    assert {:error, refused} = Projects.update_slack_workspace(system_scope(), workspace, %{"token" => "xoxb-old"})
    assert %{token: ["was refused by Slack (token_revoked)"]} = errors_on(refused)

    assert {:error, blank} = Projects.update_slack_workspace(system_scope(), workspace, %{"name" => ""})
    assert %{name: ["can't be blank"]} = errors_on(blank)
  end

  test "is for admins only", %{workspace: workspace} do
    assert {:error, :not_authorized} = Projects.update_slack_workspace(user_scope(), workspace, %{"name" => "x"})
  end
end
