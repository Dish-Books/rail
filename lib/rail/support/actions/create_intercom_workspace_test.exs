defmodule Rail.Support.Actions.CreateIntercomWorkspaceTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Intercom
  alias Rail.Support
  alias Rail.Support.Schemas.IntercomWorkspace
  alias Rail.Support.Workers.BackfillIntercomWorkspace

  setup do
    %{
      app_id: "app_#{System.unique_integer([:positive])}",
      attrs: %{"name" => "Dishbooks Support", "access_token" => "tok_ws", "client_id" => "cid", "client_secret" => "sec"}
    }
  end

  test "saves the workspace under the app its token belongs to, and starts importing", %{
    project: %{id: project_id} = project,
    app_id: app_id,
    attrs: attrs
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "intercom_workspaces")

    Req.Test.expect(Intercom, fn conn ->
      assert conn.request_path == "/me"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer tok_ws"]
      Req.Test.json(conn, %{"app" => %{"id_code" => app_id}})
    end)

    assert {:ok,
            %IntercomWorkspace{id: workspace_id, project_id: ^project_id, external_id: ^app_id, name: "Dishbooks Support"}} =
             Support.create_intercom_workspace(system_scope(), project, attrs)

    assert_enqueued(worker: BackfillIntercomWorkspace, args: %{"workspace_id" => workspace_id})
    assert_receive {:intercom_workspace_changed, ^workspace_id}
  end

  test "only an admin may connect a workspace", %{project: project, attrs: attrs} do
    assert {:error, :not_authorized} = Support.create_intercom_workspace(temp_user_scope(), project, attrs)
  end

  test "a token Intercom refuses is an error on the token, and nothing is saved", %{project: project, attrs: attrs} do
    Req.Test.expect(Intercom, &(&1 |> Plug.Conn.put_status(401) |> Req.Test.json(%{"type" => "error.list"})))

    assert {:error, %Ecto.Changeset{} = changeset} = Support.create_intercom_workspace(system_scope(), project, attrs)
    assert %{access_token: ["Intercom did not accept this token"]} = errors_on(changeset)
    refute_enqueued(worker: BackfillIntercomWorkspace)
  end

  test "a form missing a secret is refused without asking Intercom", %{project: project, attrs: attrs} do
    assert {:error, %Ecto.Changeset{} = changeset} =
             Support.create_intercom_workspace(system_scope(), project, Map.delete(attrs, "client_secret"))

    assert %{client_secret: ["can't be blank"]} = errors_on(changeset)
  end

  test "an app already connected is refused", %{project: project, app_id: app_id, attrs: attrs} do
    Req.Test.stub(Intercom, &Req.Test.json(&1, %{"app" => %{"id_code" => app_id}}))
    assert {:ok, %IntercomWorkspace{}} = Support.create_intercom_workspace(system_scope(), project, attrs)

    assert {:error, %Ecto.Changeset{} = changeset} = Support.create_intercom_workspace(system_scope(), project, attrs)
    assert %{external_id: ["has already been taken"]} = errors_on(changeset)
  end
end
