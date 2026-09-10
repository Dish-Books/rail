defmodule Rail.Roles.Actions.RoleForStageTest do
  use Rail.DataCase, async: true

  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Scope

  test "returns role bound to stage with 3-arity scope call" do
    scope = Scope.for_user(%{admin: false})
    project = create_test_project()
    %Role{id: role_id} = create_test_role(project_id: project.id, stage: :product)

    assert {:ok, %Role{id: ^role_id, stage: :product}} = Roles.role_for_stage(scope, project.id, :product)
  end

  test "returns role bound to stage with 2-arity project_id call" do
    project = create_test_project()
    %Role{id: role_id} = create_test_role(project_id: project.id, stage: :architect)

    assert {:ok, %Role{id: ^role_id, stage: :architect}} = Roles.role_for_stage(project.id, :architect)
  end

  test "accepts string representation of stage" do
    project = create_test_project()
    %Role{id: role_id} = create_test_role(project_id: project.id, stage: :engineer)

    assert {:ok, %Role{id: ^role_id}} = Roles.role_for_stage(project.id, "engineer")
  end

  test "returns not found error when stage is not bound" do
    project = create_test_project()
    create_test_role(project_id: project.id, stage: :engineer)

    assert {:error, :not_found} = Roles.role_for_stage(project.id, :qa)
  end

  test "returns not found error when stage is invalid" do
    project = create_test_project()
    assert {:error, :not_found} = Roles.role_for_stage(project.id, "invalid_stage_name")
    assert {:error, :not_found} = Roles.role_for_stage(project.id, 12_345)
  end

  test "returns not authorized when scope is unauthenticated" do
    project = create_test_project()
    assert {:error, :not_authorized} = Roles.role_for_stage(nil, project.id, :engineer)
  end

  test "role_for_stage! returns role for bound stage" do
    project = create_test_project()
    %Role{id: role_id} = create_test_role(project_id: project.id, stage: :demo)

    assert %Role{id: ^role_id} = Roles.role_for_stage!(project.id, :demo)
    assert %Role{id: ^role_id} = Roles.role_for_stage!(Scope.for_system(), project.id, :demo)
  end

  test "role_for_stage! raises Ecto.NoResultsError when stage is not bound" do
    project = create_test_project()

    assert_raise Ecto.NoResultsError, fn ->
      Roles.role_for_stage!(project.id, :qa)
    end
  end

  test "resolves debugger and rebase stages" do
    project = create_test_project()
    %Role{id: deb_id} = create_test_role(project_id: project.id, stage: :debugger)
    %Role{id: reb_id} = create_test_role(project_id: project.id, stage: :rebase)

    assert {:ok, %Role{id: ^deb_id}} = Roles.role_for_stage(project.id, :debugger)
    assert {:ok, %Role{id: ^deb_id}} = Roles.role_for_stage(project.id, "debugger")
    assert {:ok, %Role{id: ^reb_id}} = Roles.role_for_stage(project.id, :rebase)
  end

  test "resolves fallback between design and designer" do
    project1 = create_test_project()
    %Role{id: des_id1} = create_test_role(project_id: project1.id, stage: :designer)
    assert {:ok, %Role{id: ^des_id1}} = Roles.role_for_stage(project1.id, :design)

    project2 = create_test_project()
    %Role{id: des_id2} = create_test_role(project_id: project2.id, stage: :design)
    assert {:ok, %Role{id: ^des_id2}} = Roles.role_for_stage(project2.id, :designer)

    project3 = create_test_project()
    assert {:error, :not_found} = Roles.role_for_stage(project3.id, :designer)
    assert {:error, :not_found} = Roles.role_for_stage(project3.id, :design)
    assert length(Roles.canonical_stages()) == 10
  end
end
