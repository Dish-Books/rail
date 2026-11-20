defmodule Rail.Support.Actions.ListIntercomWorkspacesTest do
  use Rail.DataCase, async: true

  alias Rail.Intercom
  alias Rail.Projects.Schemas.Project
  alias Rail.Support
  alias Rail.Support.Schemas.IntercomWorkspace

  test "lists every workspace by name, with its project", %{project: %{id: project_id} = project} do
    unique = System.unique_integer([:positive])

    for name <- ["Zeta #{unique}", "Alpha #{unique}"] do
      Req.Test.expect(Intercom, &Req.Test.json(&1, %{"app" => %{"id_code" => "app_#{name}"}}))

      {:ok, _workspace} =
        Support.create_intercom_workspace(system_scope(), project, %{
          "name" => name,
          "access_token" => "tok",
          "client_id" => "cid",
          "client_secret" => "sec"
        })
    end

    alpha = "Alpha #{unique}"
    zeta = "Zeta #{unique}"

    assert [
             %IntercomWorkspace{name: ^alpha, project: %Project{id: ^project_id}},
             %IntercomWorkspace{name: ^zeta}
           ] = Enum.filter(Support.list_intercom_workspaces(), &String.ends_with?(&1.name, " #{unique}"))
  end
end
