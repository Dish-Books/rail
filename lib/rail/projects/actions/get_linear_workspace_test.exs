defmodule Rail.Projects.Actions.GetLinearWorkspaceTest do
  use Rail.DataCase, async: true

  alias Rail.Projects
  alias Rail.Projects.Schemas.LinearWorkspace
  alias Rail.Projects.Schemas.Project

  test "finds a workspace by the given field" do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_id"}]}}})
    end)

    {:ok, %Project{linear_workspace: %LinearWorkspace{id: workspace_id}}} =
      Projects.create_project(system_scope(), %{
        name: "Get Workspace Project",
        github_repo: "org/get-workspace",
        github_installation_id: 12_960,
        linear_team_key: "GWS",
        default_branch: "main",
        clone_path: "/tmp/repos/get-workspace",
        linear_workspace: %{
          name: "Get Workspace",
          external_id: "lin_ws_get_workspace",
          token: "lin_api_token_get_workspace",
          webhook_secret: "whsec_get_workspace"
        }
      })

    assert {:ok, %LinearWorkspace{id: ^workspace_id}} = Projects.get_linear_workspace(id: workspace_id)
    assert {:ok, %LinearWorkspace{id: ^workspace_id}} = Projects.get_linear_workspace(external_id: "lin_ws_get_workspace")
  end

  test "returns {:error, :not_found} for an unknown workspace" do
    assert {:error, :not_found} = Projects.get_linear_workspace(id: "lin_ws_missing")
  end
end
