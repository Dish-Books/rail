defmodule Rail.Projects.Actions.SetSlackChannelsTest do
  use Rail.DataCase, async: true

  alias Rail.Projects
  alias Rail.Projects.Schemas.SlackChannel
  alias Rail.Slack

  setup do
    unique = System.unique_integer([:positive])
    team_id = "T#{unique}"
    Req.Test.expect(Slack, &Req.Test.json(&1, %{"ok" => true, "team_id" => team_id}))
    {:ok, workspace} = Projects.create_slack_workspace(system_scope(), %{"name" => "Acme", "token" => "xoxb-1"})

    Req.Test.stub(Slack, fn conn ->
      Req.Test.json(conn, %{
        "ok" => true,
        "channels" => [
          %{"id" => "C#{unique}a", "name" => "rail-feedback"},
          %{"id" => "C#{unique}b", "name" => "posthog-index"}
        ]
      })
    end)

    %{workspace: workspace, feedback: "C#{unique}a", posthog: "C#{unique}b"}
  end

  test "stores Slack's names and the bot option, and replaces the previous set", %{
    project: project,
    workspace: %{id: workspace_id},
    feedback: feedback,
    posthog: posthog
  } do
    assert {:ok, [%SlackChannel{external_id: ^feedback, name: "rail-feedback", slack_workspace_id: ^workspace_id}]} =
             Projects.set_slack_channels(system_scope(), project, [
               %{"external_id" => feedback, "triage_bot_messages" => "false"}
             ])

    assert {:ok, [%SlackChannel{external_id: ^posthog, name: "posthog-index", triage_bot_messages: true}]} =
             Projects.set_slack_channels(system_scope(), project, [
               %{"external_id" => posthog, "triage_bot_messages" => "true"}
             ])

    assert [%SlackChannel{external_id: ^posthog}] = Projects.list_slack_channels(project)
  end

  test "refuses a channel another project holds", %{project: project, feedback: feedback} do
    {:ok, other} =
      Projects.create_project(system_scope(), %{
        name: "Other",
        github_repo: "example/other-#{System.unique_integer([:positive])}",
        github_installation_id: 2,
        linear_team_key: "OTH",
        default_branch: "main",
        clone_path: "/tmp/other"
      })

    assert {:ok, [_held]} = Projects.set_slack_channels(system_scope(), other, [%{"external_id" => feedback}])

    assert {:error, changeset} = Projects.set_slack_channels(system_scope(), project, [%{"external_id" => feedback}])
    assert %{external_id: ["is connected to another project"]} = errors_on(changeset)
    assert [] = Projects.list_slack_channels(project)
  end

  test "refuses a channel Slack does not know", %{project: project} do
    assert {:error, :channel_not_found} =
             Projects.set_slack_channels(system_scope(), project, [%{"external_id" => "C_GONE"}])
  end

  test "sets nothing when Slack cannot list channels", %{project: project, feedback: feedback} do
    Req.Test.stub(Slack, &Req.Test.json(&1, %{"ok" => false, "error" => "ratelimited"}))

    assert {:error, {:slack_error, "ratelimited"}} =
             Projects.set_slack_channels(system_scope(), project, [%{"external_id" => feedback}])
  end

  test "is for admins only", %{project: project} do
    assert {:error, :not_authorized} = Projects.set_slack_channels(user_scope(), project, [])
  end
end
