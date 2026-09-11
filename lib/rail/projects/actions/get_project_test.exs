defmodule Rail.Projects.Actions.GetProjectTest do
  use Rail.DataCase, async: true

  alias Rail.Projects
  alias Rail.Projects.Schemas.Project
  alias Rail.Scope

  test "get_project/2 retrieves an existing project" do
    admin_scope = Scope.for_user(%{admin: true})
    repo = "example/get-repo-#{System.unique_integer([:positive])}"

    assert {:ok, %Project{id: project_id}} =
             Projects.create_project(admin_scope, %{
               name: "Rail Core",
               github_repo: repo,
               github_installation_id: 11_223,
               linear_team_id: "team_get",
               linear_team_key: "RC",
               default_branch: "main",
               clone_path: "/tmp/get"
             })

    user_scope = Scope.for_user(%{admin: false})
    system_scope = Scope.for_system()

    assert {:ok, %Project{id: ^project_id, name: "Rail Core"}} =
             Projects.get_project(user_scope, project_id)

    assert {:ok, %Project{id: ^project_id, name: "Rail Core"}} =
             Projects.get_project(system_scope, project_id)
  end

  test "get_project/2 returns {:error, :not_found} when project does not exist" do
    user_scope = Scope.for_user(%{admin: false})
    assert {:error, :not_found} = Projects.get_project(user_scope, "prj_000000000000000000000000")
  end

  test "get_project/2 returns {:error, :not_authorized} for nil scope" do
    assert {:error, :not_authorized} = Projects.get_project(nil, "prj_123")
    assert {:error, :not_authorized} = Projects.get_project(%Scope{user: nil}, "prj_123")
  end

  test "get_project!/2 retrieves an existing project" do
    admin_scope = Scope.for_user(%{admin: true})
    repo = "example/bang-repo-#{System.unique_integer([:positive])}"

    assert {:ok, %Project{id: project_id}} =
             Projects.create_project(admin_scope, %{
               name: "Bang Project",
               github_repo: repo,
               github_installation_id: 44_556,
               linear_team_id: "team_bang",
               linear_team_key: "BP",
               default_branch: "main",
               clone_path: "/tmp/bang"
             })

    user_scope = Scope.for_user(%{admin: false})
    system_scope = Scope.for_system()

    assert %Project{id: ^project_id, name: "Bang Project"} =
             Projects.get_project!(user_scope, project_id)

    assert %Project{id: ^project_id, name: "Bang Project"} =
             Projects.get_project!(system_scope, project_id)
  end

  test "get_project!/2 raises Ecto.NoResultsError when project does not exist" do
    user_scope = Scope.for_user(%{admin: false})

    assert_raise Ecto.NoResultsError, fn ->
      Projects.get_project!(user_scope, "prj_000000000000000000000000")
    end
  end

  test "get_project!/2 raises Ecto.NoResultsError for unauthenticated scope" do
    assert_raise Ecto.NoResultsError, fn ->
      Projects.get_project!(nil, "prj_123")
    end
  end
end
