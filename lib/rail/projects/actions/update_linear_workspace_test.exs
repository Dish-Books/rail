defmodule Rail.Projects.Actions.UpdateLinearWorkspaceTest do
  use Rail.DataCase, async: true

  alias Rail.Projects
  alias Rail.Projects.Schemas.LinearWorkspace
  alias Rail.Scope

  setup do
    {:ok, workspace} =
      Projects.create_linear_workspace(system_scope(), %{
        name: "Before",
        external_id: "lin_org_update",
        token: "lin_api_update",
        webhook_secret: "whsec_update"
      })

    %{workspace: workspace}
  end

  test "an admin updates a workspace, and a blank token keeps the saved one", %{workspace: workspace} do
    assert {:ok, %LinearWorkspace{name: "After", token: "lin_api_update", webhook_secret: "whsec_new"}} =
             Projects.update_linear_workspace(Scope.for_user(%{admin: true}), workspace, %{
               "name" => "After",
               "token" => "",
               "webhook_secret" => "whsec_new"
             })
  end

  test "rejects a non-admin", %{workspace: workspace} do
    assert {:error, :not_authorized} =
             Projects.update_linear_workspace(Scope.for_user(%{admin: false}), workspace, %{name: "Hacked"})
  end
end
