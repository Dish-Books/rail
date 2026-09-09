defmodule Rail.Roles.Actions.ImportRolesTest do
  use Rail.DataCase, async: true

  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Scope

  test "imports roles from a list of maps into a project" do
    scope = Scope.for_user(%{admin: true})
    project = create_test_project()

    roles_data = [
      %{
        "name" => "Architect",
        "stage" => "architect",
        "model" => "claude-3-7-sonnet",
        "system_prompt" => "Design architecture."
      },
      %{
        "name" => "Product Manager",
        "stage" => "product",
        "model" => "claude-3-7-sonnet",
        "system_prompt" => "Define scope."
      }
    ]

    assert {:ok, [%Role{name: "Architect"}, %Role{name: "Product Manager"}]} =
             Roles.import_roles(scope, project, roles_data)

    roles = Roles.list_roles(scope, project.id)
    assert length(roles) == 2
  end

  test "imports roles from a valid JSON string" do
    scope = Scope.for_user(%{admin: true})
    project = create_test_project()

    json_str = """
    [
      {
        "name": "Engineer",
        "stage": "engineer",
        "model": "claude-3-7-sonnet",
        "system_prompt": "Code features."
      }
    ]
    """

    assert {:ok, [%Role{name: "Engineer", stage: :engineer}]} =
             Roles.import_roles(scope, project.id, json_str)
  end

  test "imports roles from a map wrapping roles key" do
    scope = Scope.for_user(%{admin: true})
    project = create_test_project()

    data = %{
      "roles" => [
        %{
          "name" => "QA",
          "stage" => "qa",
          "model" => "claude-3-7-sonnet",
          "system_prompt" => "Verify features."
        }
      ]
    }

    assert {:ok, [%Role{name: "QA", stage: :qa}]} =
             Roles.import_roles(scope, project.id, data)

    map_atom = %{
      roles: [
        %{
          name: "Demo",
          stage: :demo,
          model: "claude-3-7-sonnet",
          system_prompt: "Record demos."
        }
      ]
    }

    assert {:ok, [%Role{name: "Demo", stage: :demo}]} =
             Roles.import_roles(scope, project.id, map_atom)
  end

  test "clears existing stage binding when imported role conflicts with an existing stage" do
    scope = Scope.for_user(%{admin: true})
    project = create_test_project()

    old_role =
      create_test_role(
        project_id: project.id,
        stage: :engineer,
        name: "Old Engineer"
      )

    roles_data = [
      %{
        "name" => "New Engineer",
        "stage" => "engineer",
        "model" => "claude-3-7-sonnet",
        "system_prompt" => "New instructions"
      }
    ]

    assert {:ok, [%Role{name: "New Engineer", stage: :engineer}]} =
             Roles.import_roles(scope, project, roles_data)

    assert {:ok, %Role{stage: nil}} = Roles.get_role(scope, old_role.id)
    assert {:ok, %Role{name: "New Engineer"}} = Roles.role_for_stage(project.id, :engineer)
  end

  test "replaces all existing roles when replace_all: true is specified" do
    scope = Scope.for_user(%{admin: true})
    project = create_test_project()

    create_test_role(project_id: project.id, name: "To Be Replaced 1")
    create_test_role(project_id: project.id, name: "To Be Replaced 2")

    roles_data = [
      %{
        "name" => "Fresh Role",
        "model" => "claude-3-7-sonnet",
        "system_prompt" => "Fresh prompt"
      }
    ]

    assert {:ok, [%Role{name: "Fresh Role"}]} =
             Roles.import_roles(scope, project, roles_data, replace_all: true)

    assert [%Role{name: "Fresh Role"}] = Roles.list_roles(scope, project.id)
  end

  test "rolls back transaction if any imported role is invalid" do
    scope = Scope.for_user(%{admin: true})
    project = create_test_project()

    roles_data = [
      %{
        "name" => "Valid Role",
        "model" => "claude-3-7-sonnet",
        "system_prompt" => "Valid"
      },
      %{
        "name" => "Invalid Role",
        # missing model and system_prompt
        "model" => nil,
        "system_prompt" => nil
      }
    ]

    assert {:error, changeset} = Roles.import_roles(scope, project, roles_data)
    assert %{model: ["can't be blank"]} = errors_on(changeset)
    assert Roles.list_roles(scope, project.id) == []
  end

  test "returns error on invalid json" do
    scope = Scope.for_user(%{admin: true})
    project = create_test_project()

    assert {:error, :invalid_json} = Roles.import_roles(scope, project, "{invalid_json")
  end

  test "returns error on invalid data shape" do
    scope = Scope.for_user(%{admin: true})
    project = create_test_project()

    assert {:error, :invalid_roles_data} = Roles.import_roles(scope, project, 12_345)
  end

  test "returns not authorized for non-admin scope" do
    scope = Scope.for_user(%{admin: false})
    project = create_test_project()

    assert {:error, :not_authorized} = Roles.import_roles(scope, project, [])
  end

  test "returns error when project is nil" do
    scope = Scope.for_user(%{admin: true})
    assert {:error, :project_not_found} = Roles.import_roles(scope, nil, [])
  end

  test "imports role without stage binding" do
    scope = Scope.for_user(%{admin: true})
    project = create_test_project()

    roles_data = [
      %{
        "name" => "Unbound Role",
        "stage" => nil,
        "model" => "claude-3-7-sonnet",
        "system_prompt" => "Generic prompt."
      }
    ]

    assert {:ok, [%Role{name: "Unbound Role", stage: nil}]} =
             Roles.import_roles(scope, project, roles_data)
  end

  test "rolls back when stage string is invalid stage name" do
    scope = Scope.for_user(%{admin: true})
    project = create_test_project()

    roles_data = [
      %{
        "name" => "Invalid Stage Role",
        "stage" => "not_a_stage",
        "model" => "claude-3-7-sonnet",
        "system_prompt" => "Prompt."
      }
    ]

    assert {:error, changeset} = Roles.import_roles(scope, project, roles_data)
    assert %{stage: ["is invalid"]} = errors_on(changeset)
  end

  test "rolls back when stage is non-string and non-atom" do
    scope = Scope.for_user(%{admin: true})
    project = create_test_project()

    roles_data = [
      %{
        "name" => "Invalid Stage Type",
        "stage" => 123,
        "model" => "claude-3-7-sonnet",
        "system_prompt" => "Prompt."
      }
    ]

    assert {:error, changeset} = Roles.import_roles(scope, project, roles_data)
    assert %{stage: ["is invalid"]} = errors_on(changeset)
  end
end
