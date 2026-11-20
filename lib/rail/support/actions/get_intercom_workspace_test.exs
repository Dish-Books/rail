defmodule Rail.Support.Actions.GetIntercomWorkspaceTest do
  use Rail.DataCase, async: true

  alias Rail.Intercom
  alias Rail.Support
  alias Rail.Support.Schemas.IntercomWorkspace

  setup %{project: project} do
    app_id = "app_#{System.unique_integer([:positive])}"
    Req.Test.expect(Intercom, &Req.Test.json(&1, %{"app" => %{"id_code" => app_id}}))

    {:ok, %IntercomWorkspace{id: workspace_id}} =
      Support.create_intercom_workspace(system_scope(), project, %{
        "name" => "Support",
        "access_token" => "tok_ws",
        "client_id" => "cid",
        "client_secret" => "sec"
      })

    %{workspace_id: workspace_id, app_id: app_id}
  end

  test "finds a workspace by its id or by Intercom's app id", %{workspace_id: workspace_id, app_id: app_id} do
    assert {:ok, %IntercomWorkspace{id: ^workspace_id}} = Support.get_intercom_workspace(id: workspace_id)
    assert {:ok, %IntercomWorkspace{id: ^workspace_id}} = Support.get_intercom_workspace(external_id: app_id)
  end

  test "an unknown workspace is not found" do
    assert {:error, :not_found} = Support.get_intercom_workspace(external_id: "app_unknown")
    assert {:error, :not_found} = Support.get_intercom_workspace(id: "iw_unknown")
  end
end
