defmodule Rail.Roles.Actions.CreateRoleTest do
  use Rail.DataCase, async: true

  alias Rail.Projects.Schemas.Project
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Scope

  test "creates role for project struct with admin scope" do
    scope = Scope.for_user(%{admin: true})
    %Project{id: project_id} = project = create_test_project()

    attrs = %{
      name: "Product Agent",
      stage: :product,
      model: "claude-3-7-sonnet",
      system_prompt: "Write PRDs."
    }

    assert {:ok, %Role{name: "Product Agent", stage: :product, project_id: ^project_id}} =
             Roles.create_role(scope, project, attrs)
  end

  test "creates role for project id with system scope" do
    scope = Scope.for_system()
    %Project{id: project_id} = create_test_project()

    attrs = %{
      name: "QA Agent",
      stage: :qa,
      model: "claude-3-7-sonnet",
      system_prompt: "Test everything."
    }

    assert {:ok, %Role{name: "QA Agent", stage: :qa, project_id: ^project_id}} =
             Roles.create_role(scope, project_id, attrs)
  end

  test "returns validation errors for missing attributes" do
    scope = Scope.for_user(%{admin: true})
    project = create_test_project()

    assert {:error, changeset} = Roles.create_role(scope, project, %{})

    assert %{
             name: ["can't be blank"],
             model: ["can't be blank"],
             system_prompt: ["can't be blank"]
           } = errors_on(changeset)
  end

  test "returns validation error when project does not exist" do
    scope = Scope.for_user(%{admin: true})

    attrs = %{
      name: "Ghost Role",
      model: "claude",
      system_prompt: "Ghost prompt"
    }

    assert {:error, changeset} = Roles.create_role(scope, "prj_000000000000000000000000", attrs)
    assert %{project_id: ["does not exist"]} = errors_on(changeset)
  end

  test "returns not authorized for non-admin user" do
    scope = Scope.for_user(%{admin: false})
    project = create_test_project()

    attrs = %{name: "Role", model: "claude", system_prompt: "Prompt"}
    assert {:error, :not_authorized} = Roles.create_role(scope, project, attrs)
  end

  test "returns not authorized for nil scope" do
    project = create_test_project()
    attrs = %{name: "Role", model: "claude", system_prompt: "Prompt"}
    assert {:error, :not_authorized} = Roles.create_role(nil, project, attrs)
  end

  test "returns validation error when project_or_id is invalid type" do
    scope = Scope.for_system()
    attrs = %{name: "Role", model: "claude", system_prompt: "Prompt"}
    assert {:error, changeset} = Roles.create_role(scope, :invalid_project, attrs)
    assert %{project_id: ["can't be blank"]} = errors_on(changeset)
  end
end
