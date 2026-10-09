defmodule Rail.Projects.Actions.ListSlackChannelsTest do
  use Rail.DataCase, async: true

  alias Rail.Projects
  alias Rail.Projects.Schemas.SlackChannel

  setup %{project: project} do
    unique = System.unique_integer([:positive])
    Req.Test.expect(Rail.Slack, &Req.Test.json(&1, %{"ok" => true, "team_id" => "T#{unique}"}))
    {:ok, workspace} = Projects.create_slack_workspace(system_scope(), %{"name" => "Acme", "token" => "xoxb-1"})

    {:ok, other} =
      Projects.create_project(system_scope(), %{
        name: "Other",
        github_repo: "example/other-#{unique}",
        github_installation_id: 2,
        linear_team_key: "OTH",
        default_branch: "main",
        clone_path: "/tmp/other"
      })

    channel = fn id, name -> %{"external_id" => id, "name" => name, "slack_workspace_id" => workspace.id} end

    {:ok, _project} =
      Projects.update_project(system_scope(), project, %{"slack_channels" => [channel.("C#{unique}z", "zebra")]})

    {:ok, _other} =
      Projects.update_project(system_scope(), other, %{"slack_channels" => [channel.("C#{unique}a", "alpha")]})

    %{other: other, workspace: workspace}
  end

  test "lists one project's channels, or several projects' in one query, by name", %{project: project, other: other} do
    assert [%SlackChannel{name: "zebra"}] = Projects.list_slack_channels(project)
    assert [%SlackChannel{name: "alpha"}, %SlackChannel{name: "zebra"}] = Projects.list_slack_channels([project, other])
    assert [] = Projects.list_slack_channels([])
  end

  test "lists a workspace's channels across projects, by name", %{workspace: workspace} do
    assert [%SlackChannel{name: "alpha"}, %SlackChannel{name: "zebra"}] = Projects.list_slack_channels(workspace)
  end

  test "lists every project's channels marked external", %{other: other, workspace: workspace} do
    assert [] = Projects.list_slack_channels(external: true)

    {:ok, _other} =
      Projects.update_project(system_scope(), other, %{
        "slack_channels" => [
          %{
            "external_id" => "C_OUTSIDE",
            "name" => "customer",
            "slack_workspace_id" => workspace.id,
            "external" => "true"
          }
        ]
      })

    assert [%SlackChannel{external_id: "C_OUTSIDE", external: true}] = Projects.list_slack_channels(external: true)
  end
end
