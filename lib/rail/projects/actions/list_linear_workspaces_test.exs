defmodule Rail.Projects.Actions.ListLinearWorkspacesTest do
  use Rail.DataCase, async: true

  alias Rail.Projects
  alias Rail.Projects.Schemas.LinearWorkspace
  alias Rail.Projects.Schemas.Project

  test "lists workspaces by name, each with the projects on it", %{project: %Project{id: project_id}} do
    {:ok, _workspace} =
      Projects.create_linear_workspace(system_scope(), %{
        name: "Aardvark",
        external_id: "lin_org_list",
        token: "lin_api_list",
        webhook_secret: "whsec_list"
      })

    assert [%LinearWorkspace{name: "Aardvark", projects: []}, %LinearWorkspace{projects: [%Project{id: ^project_id}]}] =
             Projects.list_linear_workspaces()
  end
end
