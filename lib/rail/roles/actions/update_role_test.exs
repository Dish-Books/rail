defmodule Rail.Roles.Actions.UpdateRoleTest do
  use Rail.DataCase, async: true

  alias Rail.Projects.Schemas.Project
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Scope

  setup do
    project =
      %Project{}
      |> Project.changeset(%{
        name: "Update Role Project",
        github_repo: "org/update-role",
        github_installation_id: 4405,
        linear_team_key: "URL",
        default_branch: "main",
        clone_path: "/tmp/repos/update-role"
      })
      |> Repo.insert!()

    {:ok, backend} =
      Rail.Tools.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true"})

    scope = system_scope()

    {:ok, role} =
      Roles.create_role(scope, project, %{
        backend_id: backend.id,
        name: "Old Name",
        stage: :engineer,
        model: "claude-opus-5-5",
        system_prompt: "Old prompt"
      })

    %{project: project, role: role}
  end

  test "updates role attributes with admin scope", %{role: role} do
    scope = Scope.for_user(%{admin: true})

    attrs = %{
      name: "New Name",
      system_prompt: "New prompt",
      position: 5,
      max_concurrent: 3
    }

    assert {:ok, %Role{name: "New Name", system_prompt: "New prompt", position: 5, max_concurrent: 3}} =
             Roles.update_role(scope, role, attrs)
  end

  test "updates role attributes with system scope", %{role: role} do
    scope = Scope.for_system()

    assert {:ok, %Role{model: "claude-next"}} =
             Roles.update_role(scope, role, %{model: "claude-next"})
  end

  test "returns validation errors on invalid updates", %{role: role} do
    scope = Scope.for_user(%{admin: true})

    assert {:error, changeset} = Roles.update_role(scope, role, %{max_concurrent: 0, model: nil})

    assert %{
             max_concurrent: ["must be greater than or equal to 1"],
             model: ["can't be blank"]
           } = errors_on(changeset)
  end

  # Capacity in test is 4 CPUs and 8 GB (config/test.exs), so 16 CPUs could never start.
  test "refuses a reservation larger than the machine can ever free", %{role: role} do
    assert {:error, changeset} = Roles.update_role(system_scope(), role, %{reserved_cpus: 16, reserved_memory_gb: 64})

    assert %{
             reserved_cpus: ["This machine has 4 CPUs to reserve, so an Old Name that needs 16 could never start."],
             reserved_memory_gb: ["This machine has 8 GB to reserve, so an Old Name that needs 64 GB could never start."]
           } = errors_on(changeset)
  end

  test "saves any reservation while Docker cannot say what the machine has", %{role: role} do
    expect(Rail.Tools, :get_sandbox_capacity, fn -> {:error, :econnrefused} end)

    assert {:ok, %Role{reserved_cpus: 16}} = Roles.update_role(system_scope(), role, %{reserved_cpus: 16})
  end

  test "saves a reservation the machine can hold", %{role: role} do
    assert {:ok, %Role{reserved_cpus: 2, reserved_memory_gb: 4}} =
             Roles.update_role(system_scope(), role, %{reserved_cpus: 2, reserved_memory_gb: 4})
  end

  test "returns not authorized for non-admin scope", %{role: role} do
    scope = Scope.for_user(%{admin: false})

    assert {:error, :not_authorized} = Roles.update_role(scope, role, %{name: "Updated"})
  end

  test "returns not authorized for nil scope", %{role: role} do
    assert {:error, :not_authorized} = Roles.update_role(nil, role, %{name: "Updated"})
  end
end
