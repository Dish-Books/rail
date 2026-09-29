defmodule Rail.Projects.Actions.GetSlackWorkspaceTest do
  use Rail.DataCase, async: true

  alias Rail.Projects
  alias Rail.Projects.Schemas.SlackWorkspace

  setup do
    team_id = "T#{System.unique_integer([:positive])}"
    Req.Test.expect(Rail.Slack, &Req.Test.json(&1, %{"ok" => true, "team_id" => team_id}))
    {:ok, workspace} = Projects.create_slack_workspace(system_scope(), %{"name" => "Acme", "token" => "xoxb-1"})
    %{workspace: workspace}
  end

  test "finds a workspace by what it is given", %{workspace: %{id: id, external_id: team_id}} do
    assert {:ok, %SlackWorkspace{id: ^id}} = Projects.get_slack_workspace(external_id: team_id)
    assert {:error, :not_found} = Projects.get_slack_workspace(id: "sw_missing")
  end

  test "lists every workspace", %{workspace: %{id: id}} do
    assert Enum.any?(Projects.list_slack_workspaces(), &match?(%SlackWorkspace{id: ^id}, &1))
  end
end
