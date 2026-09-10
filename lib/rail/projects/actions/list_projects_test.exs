defmodule Rail.Projects.Actions.ListProjectsTest do
  use Rail.DataCase, async: true

  alias Rail.Projects
  alias Rail.Projects.Schemas.Project
  alias Rail.Scope

  test "lists projects for authenticated user scope in alphabetical order" do
    admin_scope = Scope.for_user(%{admin: true})
    id = System.unique_integer([:positive])

    assert {:ok, %Project{id: p1_id, name: "Zeta Project"}} =
             Projects.create_project(admin_scope, %{
               name: "Zeta Project",
               github_repo: "example/zeta-#{id}",
               github_installation_id: id,
               linear_team_id: "team_z",
               linear_team_key: "ZET",
               clone_path: "/tmp/zeta"
             })

    assert {:ok, %Project{id: p2_id, name: "Alpha Project"}} =
             Projects.create_project(admin_scope, %{
               name: "Alpha Project",
               github_repo: "example/alpha-#{id}",
               github_installation_id: id + 1,
               linear_team_id: "team_a",
               linear_team_key: "ALP",
               clone_path: "/tmp/alpha"
             })

    user_scope = Scope.for_user(%{admin: false})
    projects = Projects.list_projects(user_scope)

    subset = Enum.filter(projects, fn %Project{id: id} -> id in [p1_id, p2_id] end)
    assert [%Project{id: ^p2_id, name: "Alpha Project"}, %Project{id: ^p1_id, name: "Zeta Project"}] = subset
  end

  test "lists projects for system scope" do
    id = System.unique_integer([:positive])
    admin_scope = Scope.for_user(%{admin: true})

    assert {:ok, %Project{id: project_id}} =
             Projects.create_project(admin_scope, %{
               name: "System Scope Project #{id}",
               github_repo: "example/sys-#{id}",
               github_installation_id: id,
               linear_team_id: "team_sys",
               linear_team_key: "SYS",
               clone_path: "/tmp/sys"
             })

    system_scope = Scope.for_system()
    projects = Projects.list_projects(system_scope)

    assert [%Project{id: ^project_id}] =
             Enum.filter(projects, fn %Project{id: id} -> id == project_id end)
  end

  test "returns empty list for unauthenticated or nil scope" do
    assert [] = Projects.list_projects(nil)
    assert [] = Projects.list_projects(%Scope{user: nil})
  end
end
