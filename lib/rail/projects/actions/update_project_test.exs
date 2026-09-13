defmodule Rail.Projects.Actions.UpdateProjectTest do
  use Rail.DataCase, async: true

  alias Rail.Projects
  alias Rail.Projects.Schemas.Project
  alias Rail.Scope

  test "admin updates project successfully" do
    admin_scope = Scope.for_user(%{admin: true})
    repo = "example/update-repo-#{System.unique_integer([:positive])}"

    assert {:ok, %Project{id: project_id} = project} =
             Projects.create_project(admin_scope, %{
               name: "Original Name",
               github_repo: repo,
               github_installation_id: 55_667,
               linear_team_id: "team_upd",
               linear_team_key: "ORIG",
               default_branch: "main",
               clone_path: "/tmp/orig"
             })

    assert {:ok, %Project{id: ^project_id, name: "Updated Name", active: false, default_branch: "develop"}} =
             Projects.update_project(admin_scope, project, %{
               name: "Updated Name",
               active: false,
               default_branch: "develop"
             })
  end

  test "returns validation error changeset for invalid attributes" do
    admin_scope = Scope.for_user(%{admin: true})
    repo = "example/invalid-update-repo-#{System.unique_integer([:positive])}"

    assert {:ok, %Project{} = project} =
             Projects.create_project(admin_scope, %{
               name: "Valid Project",
               github_repo: repo,
               github_installation_id: 55_669,
               linear_team_id: "team_inv",
               linear_team_key: "INV",
               default_branch: "main",
               clone_path: "/tmp/inv"
             })

    assert {:error, changeset} = Projects.update_project(admin_scope, project, %{name: ""})
    assert %{name: ["can't be blank"]} = errors_on(changeset)
  end

  test "rejects non-admin user scope" do
    admin_scope = Scope.for_user(%{admin: true})
    repo = "example/unauth-update-repo-#{System.unique_integer([:positive])}"

    assert {:ok, %Project{} = project} =
             Projects.create_project(admin_scope, %{
               name: "Project to Guard",
               github_repo: repo,
               github_installation_id: 55_670,
               linear_team_id: "team_guard",
               linear_team_key: "GRD",
               default_branch: "main",
               clone_path: "/tmp/guard"
             })

    user_scope = Scope.for_user(%{admin: false})
    assert {:error, :not_authorized} = Projects.update_project(user_scope, project, %{name: "Hacked"})
  end

  test "rejects nil scope" do
    admin_scope = Scope.for_user(%{admin: true})
    repo = "example/nil-update-repo-#{System.unique_integer([:positive])}"

    assert {:ok, %Project{} = project} =
             Projects.create_project(admin_scope, %{
               name: "Project to Guard Nil",
               github_repo: repo,
               github_installation_id: 55_671,
               linear_team_id: "team_guard_nil",
               linear_team_key: "GRDN",
               default_branch: "main",
               clone_path: "/tmp/guard_nil"
             })

    assert {:error, :not_authorized} = Projects.update_project(nil, project, %{name: "Hacked"})
  end
end
