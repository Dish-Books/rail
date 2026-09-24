defmodule Rail.Projects.Actions.GetLinearWorkspaceTest do
  use Rail.DataCase, async: true

  alias Rail.Projects
  alias Rail.Projects.Schemas.LinearWorkspace
  alias Rail.Projects.Schemas.Project

  test "finds a workspace by the given field, with the projects on it", %{
    project: %Project{id: project_id, linear_workspace_id: workspace_id}
  } do
    assert {:ok, %LinearWorkspace{id: ^workspace_id, projects: [%Project{id: ^project_id}]}} =
             Projects.get_linear_workspace(id: workspace_id)

    assert {:ok, %LinearWorkspace{id: ^workspace_id}} = Projects.get_linear_workspace(external_id: "lin_org_test_seed")
  end

  test "returns {:error, :not_found} for an unknown workspace" do
    assert {:error, :not_found} = Projects.get_linear_workspace(id: "lin_ws_missing")
  end
end
