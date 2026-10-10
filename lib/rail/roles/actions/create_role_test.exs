defmodule Rail.Roles.Actions.CreateRoleTest do
  use Rail.DataCase, async: true

  alias Rail.Projects.Schemas.Project
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Scope

  setup do
    project =
      %Project{}
      |> Project.changeset(%{
        name: "Create Role Project",
        github_repo: "org/create-role",
        github_installation_id: 4402,
        key: "CRL",
        default_branch: "main",
        clone_path: "/tmp/repos/create-role"
      })
      |> Repo.insert!()

    %{project: project}
  end

  test "creates role for project struct with admin scope", %{
    project: %Project{id: project_id} = project
  } do
    scope = Scope.for_user(%{admin: true})

    attrs = %{
      cli: :claude,
      name: "Product Agent",
      stage: :product,
      model: "claude-opus-5-5",
      system_prompt: "Write PRDs."
    }

    assert {:ok, %Role{name: "Product Agent", stage: :product, project_id: ^project_id}} =
             Roles.create_role(scope, project, attrs)
  end

  test "creates role with system scope", %{project: %Project{id: project_id} = project} do
    scope = Scope.for_system()

    attrs = %{
      cli: :claude,
      name: "QA Agent",
      stage: :qa,
      model: "claude-opus-5-5",
      system_prompt: "Test everything."
    }

    assert {:ok, %Role{name: "QA Agent", stage: :qa, project_id: ^project_id}} =
             Roles.create_role(scope, project, attrs)
  end

  test "reserves 1 CPU and 2 GB unless told otherwise, and refuses more than the machine has", %{
    project: project
  } do
    attrs = %{cli: :claude, name: "Engineer", model: "claude-opus-5-5", system_prompt: "Build."}

    assert {:ok, %Role{reserved_cpus: 1, reserved_memory_gb: 2}} = Roles.create_role(system_scope(), project, attrs)

    assert {:error, changeset} = Roles.create_role(system_scope(), project, Map.put(attrs, :reserved_cpus, 16))

    assert %{reserved_cpus: ["This machine has 4 CPUs to reserve, so an Engineer that needs 16 could never start."]} =
             errors_on(changeset)
  end

  test "returns validation errors for missing attributes", %{project: project} do
    scope = Scope.for_user(%{admin: true})

    assert {:error, changeset} = Roles.create_role(scope, project, %{})

    assert %{
             name: ["can't be blank"],
             model: ["can't be blank"],
             system_prompt: ["can't be blank"],
             cli: ["can't be blank"]
           } = errors_on(changeset)
  end

  test "returns validation error when project does not exist" do
    scope = Scope.for_user(%{admin: true})

    attrs = %{
      cli: :claude,
      name: "Ghost Role",
      model: "claude",
      system_prompt: "Ghost prompt"
    }

    assert {:error, changeset} = Roles.create_role(scope, %Project{id: "prj_000000000000000000000000"}, attrs)
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
end
