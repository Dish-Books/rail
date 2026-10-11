defmodule Rail.Projects.Actions.ListProjectsTest do
  use Rail.DataCase, async: true

  alias Rail.Projects
  alias Rail.Projects.Schemas.Project
  alias Rail.Scope

  test "lists projects in alphabetical order" do
    admin_scope = Scope.for_user(%{admin: true})
    id = System.unique_integer([:positive])

    assert {:ok, %Project{id: p1_id, name: "Zeta Project"}} =
             Projects.create_project(admin_scope, %{
               name: "Zeta Project",
               github_repo: "example/zeta-#{id}",
               github_installation_id: id,
               key: "ZET",
               default_branch: "main",
               clone_path: "/tmp/zeta"
             })

    assert {:ok, %Project{id: p2_id, name: "Alpha Project"}} =
             Projects.create_project(admin_scope, %{
               name: "Alpha Project",
               github_repo: "example/alpha-#{id}",
               github_installation_id: id + 1,
               key: "ALP",
               default_branch: "main",
               clone_path: "/tmp/alpha"
             })

    projects = Projects.list_projects(admin_scope)

    subset = Enum.filter(projects, fn %Project{id: id} -> id in [p1_id, p2_id] end)
    assert [%Project{id: ^p2_id, name: "Alpha Project"}, %Project{id: ^p1_id, name: "Zeta Project"}] = subset
  end

  test "lists all projects" do
    id = System.unique_integer([:positive])
    admin_scope = Scope.for_user(%{admin: true})

    assert {:ok, %Project{id: project_id}} =
             Projects.create_project(admin_scope, %{
               name: "System Scope Project #{id}",
               github_repo: "example/sys-#{id}",
               github_installation_id: id,
               key: "SYS",
               default_branch: "main",
               clone_path: "/tmp/sys"
             })

    projects = Projects.list_projects(admin_scope)

    assert [%Project{id: ^project_id}] =
             Enum.filter(projects, fn %Project{id: id} -> id == project_id end)
  end

  test "a user lists only the projects they are granted, and an admin lists every one", %{
    project: %Project{id: project_id}
  } do
    admin_scope = Scope.for_user(%{admin: true})
    id = System.unique_integer([:positive])

    assert {:ok, %Project{id: other_id}} =
             Projects.create_project(admin_scope, %{
               name: "Granted Elsewhere #{id}",
               github_repo: "example/granted-#{id}",
               github_installation_id: id,
               key: "GRA",
               default_branch: "main",
               clone_path: "/tmp/granted"
             })

    ids = [project_id, other_id]

    visible =
      &(&1 |> Projects.list_projects() |> Enum.map(fn %Project{id: id} -> id end) |> Enum.filter(fn id -> id in ids end))

    assert visible.(user_scope(project_ids: [project_id])) == [project_id]
    assert [project_ids: ids] |> user_scope() |> visible.() |> Enum.sort() == Enum.sort(ids)
    assert admin_scope |> visible.() |> Enum.sort() == Enum.sort(ids)
    assert system_scope() |> visible.() |> Enum.sort() == Enum.sort(ids)
    assert Projects.list_projects(user_scope(project_ids: [])) == []
  end

  test "a project created after a user was granted access lists only for admins", %{project: project} do
    admin_scope = Scope.for_user(%{admin: true})
    restricted = user_scope(project_ids: [project.id])
    id = System.unique_integer([:positive])

    assert {:ok, %Project{id: new_id}} =
             Projects.create_project(admin_scope, %{
               name: "Created Later #{id}",
               github_repo: "example/later-#{id}",
               github_installation_id: id,
               key: "LAT",
               default_branch: "main",
               clone_path: "/tmp/later"
             })

    assert Enum.any?(Projects.list_projects(admin_scope), &(&1.id == new_id))
    refute Enum.any?(Projects.list_projects(restricted), &(&1.id == new_id))
  end
end
