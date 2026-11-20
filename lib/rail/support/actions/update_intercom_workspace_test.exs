defmodule Rail.Support.Actions.UpdateIntercomWorkspaceTest do
  use Rail.DataCase, async: true

  alias Rail.Intercom
  alias Rail.Repo
  alias Rail.Support
  alias Rail.Support.Schemas.IntercomWorkspace

  setup %{project: project} do
    app_id = "app_#{System.unique_integer([:positive])}"
    Req.Test.expect(Intercom, &Req.Test.json(&1, %{"app" => %{"id_code" => app_id}}))

    {:ok, workspace} =
      Support.create_intercom_workspace(system_scope(), project, %{
        "name" => "Support",
        "access_token" => "tok_ws",
        "client_id" => "cid",
        "client_secret" => "sec"
      })

    %{workspace: workspace, app_id: app_id}
  end

  test "renames without asking Intercom, keeping a secret left blank", %{
    workspace: %{id: workspace_id} = workspace,
    app_id: app_id
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "intercom_workspaces")

    assert {:ok, %IntercomWorkspace{name: "Renamed"}} =
             Support.update_intercom_workspace(system_scope(), workspace, %{
               "name" => "Renamed",
               "access_token" => "",
               "client_secret" => ""
             })

    assert %IntercomWorkspace{access_token: "tok_ws", client_secret: "sec", external_id: ^app_id} =
             Repo.get!(IntercomWorkspace, workspace_id)

    assert_receive {:intercom_workspace_changed, ^workspace_id}
  end

  test "a new token is checked with Intercom and moves the workspace to its app", %{workspace: workspace} do
    Req.Test.expect(Intercom, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer tok_new"]
      Req.Test.json(conn, %{"app" => %{"id_code" => "app_moved_#{workspace.id}"}})
    end)

    assert {:ok, %IntercomWorkspace{access_token: "tok_new", external_id: "app_moved_" <> _id}} =
             Support.update_intercom_workspace(system_scope(), workspace, %{"access_token" => "tok_new"})
  end

  test "a new token Intercom refuses leaves the workspace as it was", %{workspace: %{id: workspace_id} = workspace} do
    Req.Test.expect(Intercom, &Plug.Conn.send_resp(&1, 401, "no"))

    assert {:error, %Ecto.Changeset{}} =
             Support.update_intercom_workspace(system_scope(), workspace, %{"access_token" => "tok_bad"})

    assert %IntercomWorkspace{access_token: "tok_ws"} = Repo.get!(IntercomWorkspace, workspace_id)
  end

  test "only an admin may edit a workspace", %{workspace: workspace} do
    assert {:error, :not_authorized} = Support.update_intercom_workspace(temp_user_scope(), workspace, %{"name" => "X"})
  end
end
