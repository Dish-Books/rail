defmodule Rail.Projects.Actions.GetProjectTest do
  use Rail.DataCase, async: true

  alias Rail.Projects
  alias Rail.Projects.Schemas.Project
  alias Rail.Projects.Schemas.SlackWorkspace
  alias Rail.Scope

  test "retrieves an existing project" do
    admin_scope = Scope.for_user(%{admin: true})
    repo = "example/get-repo-#{System.unique_integer([:positive])}"

    assert {:ok, %Project{id: project_id}} =
             Projects.create_project(admin_scope, %{
               name: "Rail Core",
               github_repo: repo,
               github_installation_id: 11_223,
               linear_team_key: "RC",
               default_branch: "main",
               clone_path: "/tmp/get"
             })

    assert {:ok, %Project{id: ^project_id, name: "Rail Core"}} =
             Projects.get_project(project_id)
  end

  test "comes with the workspace its learnings digest posts through", %{project: project} do
    Req.Test.expect(Rail.Slack, &Req.Test.json(&1, %{"ok" => true, "team_id" => "T_GET"}))
    {:ok, %{id: workspace_id}} = Projects.create_slack_workspace(system_scope(), %{"name" => "Acme", "token" => "xoxb"})

    {:ok, _project} =
      Projects.update_project(system_scope(), project, %{
        "learnings_slack_workspace_id" => workspace_id,
        "learnings_channel_external_id" => "C_LEARN"
      })

    assert {:ok, %Project{learnings_slack_workspace: %SlackWorkspace{id: ^workspace_id}}} =
             Projects.get_project(project.id)
  end

  test "returns {:error, :not_found} when project does not exist" do
    assert {:error, :not_found} = Projects.get_project("prj_000000000000000000000000")
  end
end
