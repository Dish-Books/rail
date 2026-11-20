defmodule Rail.Support.Schemas.IntercomWorkspaceTest do
  use Rail.DataCase, async: true

  alias Rail.Support.Schemas.IntercomWorkspace

  test "a new workspace takes its project from the project, never the attrs", %{project: %{id: project_id} = project} do
    assert %Ecto.Changeset{valid?: true, data: %IntercomWorkspace{project_id: ^project_id}, changes: changes} =
             IntercomWorkspace.create_changeset(project, %{
               "name" => "Support",
               "access_token" => "tok",
               "client_id" => "cid",
               "client_secret" => "sec",
               "project_id" => "prj_other"
             })

    refute Map.has_key?(changes, :project_id)
  end

  test "a blank secret keeps the stored one" do
    workspace = %IntercomWorkspace{
      name: "A",
      project_id: "prj_1",
      access_token: "tok",
      client_id: "cid",
      client_secret: "sec"
    }

    assert %Ecto.Changeset{valid?: true, changes: %{name: "B"} = changes} =
             IntercomWorkspace.changeset(workspace, %{"name" => "B", "access_token" => "", "client_secret" => nil})

    refute Map.has_key?(changes, :access_token)
  end

  test "the app id comes from what Intercom's /me said" do
    changeset = IntercomWorkspace.changeset(%IntercomWorkspace{}, %{})

    assert %Ecto.Changeset{changes: %{external_id: "app_1"}} =
             IntercomWorkspace.identity_changeset(changeset, %{"app" => %{"id_code" => "app_1"}})

    assert %{access_token: ["Intercom did not say which app this token belongs to" | _rest]} =
             errors_on(IntercomWorkspace.identity_changeset(changeset, %{"type" => "admin"}))
  end

  test "the inbox link opens the conversation in the app's inbox" do
    assert "https://app.intercom.com/a/inbox/app_1/inbox/conversation/77" =
             IntercomWorkspace.inbox_url(%IntercomWorkspace{external_id: "app_1"}, "77")
  end
end
