defmodule Rail.Projects.Actions.GetSlackChannelTest do
  use Rail.DataCase, async: true

  alias Rail.Projects
  alias Rail.Projects.Schemas.Project
  alias Rail.Projects.Schemas.SlackChannel
  alias Rail.Projects.Schemas.SlackWorkspace
  alias Rail.Slack

  setup %{project: project} do
    unique = System.unique_integer([:positive])
    Req.Test.expect(Slack, &Req.Test.json(&1, %{"ok" => true, "team_id" => "T#{unique}"}))
    {:ok, workspace} = Projects.create_slack_workspace(system_scope(), %{"name" => "Acme", "token" => "xoxb-1"})
    Req.Test.expect(Slack, &Req.Test.json(&1, %{"ok" => true, "channels" => [%{"id" => "C#{unique}", "name" => "fb"}]}))
    {:ok, _channels} = Projects.set_slack_channels(system_scope(), project, [%{"external_id" => "C#{unique}"}])
    %{channel_id: "C#{unique}", workspace: workspace}
  end

  test "finds a channel with its workspace and project", %{channel_id: channel_id, workspace: %{id: workspace_id}} do
    assert {:ok,
            %SlackChannel{
              external_id: ^channel_id,
              slack_workspace: %SlackWorkspace{id: ^workspace_id},
              project: %Project{id: "prj_test_seed", triage_user: nil}
            }} = Projects.get_slack_channel(external_id: channel_id)

    assert {:error, :not_found} = Projects.get_slack_channel(external_id: "C_NONE")
  end
end
