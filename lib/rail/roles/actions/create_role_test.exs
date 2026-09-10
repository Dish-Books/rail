defmodule Rail.Roles.Actions.CreateRoleTest do
  use Rail.DataCase, async: true

  alias Rail.Projects
  alias Rail.Projects.Schemas.Project
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Scope

  setup do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Create Role Project",
        github_repo: "org/create-role",
        github_installation_id: 4101,
        linear_team_id: "team_create_role",
        linear_team_key: "CRR",
        clone_path: "/tmp/repos/create-role"
      })

    %{project: project}
  end

  test "creates role for project struct with admin scope", %{project: project} do
    scope = Scope.for_user(%{admin: true})
    %Project{id: project_id} = project

    attrs = %{
      name: "Product Agent",
      stage: :product,
      model: "claude-3-7-sonnet",
      system_prompt: "Write PRDs."
    }

    assert {:ok, %Role{name: "Product Agent", stage: :product, project_id: ^project_id}} =
             Roles.create_role(scope, project, attrs)
  end

  test "creates role for project id with system scope", %{project: project} do
    scope = Scope.for_system()
    %Project{id: project_id} = project

    attrs = %{
      name: "QA Agent",
      stage: :qa,
      model: "claude-3-7-sonnet",
      system_prompt: "Test everything."
    }

    assert {:ok, %Role{name: "QA Agent", stage: :qa, project_id: ^project_id}} =
             Roles.create_role(scope, project_id, attrs)
  end

  test "returns validation errors for missing attributes", %{project: project} do
    scope = Scope.for_user(%{admin: true})

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

  test "returns not authorized for non-admin user", %{project: project} do
    scope = Scope.for_user(%{admin: false})

    attrs = %{name: "Role", model: "claude", system_prompt: "Prompt"}
    assert {:error, :not_authorized} = Roles.create_role(scope, project, attrs)
  end

  test "returns not authorized for nil scope", %{project: project} do
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
