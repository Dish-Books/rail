defmodule Rail.Roles.Actions.RoleForStageTest do
  use Rail.DataCase, async: true

  alias Rail.Projects
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Scope

  setup do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Role For Stage Project",
        github_repo: "org/role-for-stage",
        github_installation_id: 4401,
        linear_team_id: "team_role_for_stage",
        linear_team_key: "RFS",
        clone_path: "/tmp/repos/role-for-stage"
      })

    %{project: project}
  end

  test "returns role bound to stage with 3-arity scope call", %{project: project} do
    scope = Scope.for_user(%{admin: false})

    {:ok, %Role{id: role_id}} =
      Roles.create_role(system_scope(), project, %{
        name: "Product",
        stage: :product,
        model: "claude-3-7-sonnet",
        system_prompt: "Write PRDs."
      })

    assert {:ok, %Role{id: ^role_id, stage: :product}} = Roles.role_for_stage(scope, project.id, :product)
  end

  test "returns role bound to stage with 2-arity project_id call", %{project: project} do
    {:ok, %Role{id: role_id}} =
      Roles.create_role(system_scope(), project, %{
        name: "Architect",
        stage: :architect,
        model: "claude-3-7-sonnet",
        system_prompt: "Design architecture."
      })

    assert {:ok, %Role{id: ^role_id, stage: :architect}} = Roles.role_for_stage(project.id, :architect)
  end

  test "accepts string representation of stage", %{project: project} do
    {:ok, %Role{id: role_id}} =
      Roles.create_role(system_scope(), project, %{
        name: "Engineer",
        stage: :engineer,
        model: "claude-3-7-sonnet",
        system_prompt: "Write code."
      })

    assert {:ok, %Role{id: ^role_id}} = Roles.role_for_stage(project.id, "engineer")
  end

  test "returns not found error when stage is not bound", %{project: project} do
    {:ok, _engineer} =
      Roles.create_role(system_scope(), project, %{
        name: "Engineer",
        stage: :engineer,
        model: "claude-3-7-sonnet",
        system_prompt: "Write code."
      })

    assert {:error, :not_found} = Roles.role_for_stage(project.id, :qa)
  end

  test "returns not found error when stage is invalid", %{project: project} do
    assert {:error, :not_found} = Roles.role_for_stage(project.id, "invalid_stage_name")
    assert {:error, :not_found} = Roles.role_for_stage(project.id, 12_345)
  end

  test "returns not authorized when scope is unauthenticated", %{project: project} do
    assert {:error, :not_authorized} = Roles.role_for_stage(nil, project.id, :engineer)
  end

  test "role_for_stage! returns role for bound stage", %{project: project} do
    {:ok, %Role{id: role_id}} =
      Roles.create_role(system_scope(), project, %{
        name: "Demo",
        stage: :demo,
        model: "claude-3-7-sonnet",
        system_prompt: "Record demos."
      })

    assert %Role{id: ^role_id} = Roles.role_for_stage!(project.id, :demo)
    assert %Role{id: ^role_id} = Roles.role_for_stage!(Scope.for_system(), project.id, :demo)
  end

  test "role_for_stage! raises Ecto.NoResultsError when stage is not bound", %{project: project} do
    assert_raise Ecto.NoResultsError, fn ->
      Roles.role_for_stage!(project.id, :qa)
    end
  end

  test "resolves debugger stage", %{project: project} do
    {:ok, %Role{id: deb_id}} =
      Roles.create_role(system_scope(), project, %{
        name: "Debugger",
        stage: :debugger,
        model: "claude-3-7-sonnet",
        system_prompt: "Debug failures."
      })

    assert {:ok, %Role{id: ^deb_id}} = Roles.role_for_stage(project.id, :debugger)
    assert {:ok, %Role{id: ^deb_id}} = Roles.role_for_stage(project.id, "debugger")
  end

  test "resolves design stage under the same name tasks use", %{project: project} do
    scope = system_scope()

    {:ok, %Role{id: des_id}} =
      Roles.create_role(scope, project, %{
        name: "Design",
        stage: :design,
        model: "claude-3-7-sonnet",
        system_prompt: "Design screens."
      })

    assert {:ok, %Role{id: ^des_id}} = Roles.role_for_stage(project.id, :design)
    assert {:ok, %Role{id: ^des_id}} = Roles.role_for_stage(project.id, "design")

    {:ok, other_project} =
      Projects.create_project(scope, %{
        name: "Role For Stage Project 2",
        github_repo: "org/role-for-stage-2",
        github_installation_id: 4402,
        linear_team_id: "team_role_for_stage_2",
        linear_team_key: "RF2",
        clone_path: "/tmp/repos/role-for-stage-2"
      })

    assert {:error, :not_found} = Roles.role_for_stage(other_project.id, :design)

    # `:designer` is no longer a stage a role can bind to.
    assert {:error, :not_found} = Roles.role_for_stage(project.id, :designer)
    assert length(Roles.canonical_stages()) == 9
  end
end
