defmodule Rail.Projects.Actions.GetProjectTest do
  use Rail.DataCase, async: true

  alias Rail.Projects
  alias Rail.Projects.Schemas.Project
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

  test "returns {:error, :not_found} when project does not exist" do
    assert {:error, :not_found} = Projects.get_project("prj_000000000000000000000000")
  end
end
