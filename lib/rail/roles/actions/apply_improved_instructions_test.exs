defmodule Rail.Roles.Actions.ApplyImprovedInstructionsTest do
  use Rail.DataCase, async: true

  alias Rail.Projects
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Scope

  setup do
    {:ok, backend} =
      Rail.Backends.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true"})

    scope = system_scope()

    {:ok, project} =
      Projects.create_project(scope, %{
        name: "Apply Instructions Project",
        github_repo: "org/apply-instructions",
        github_installation_id: 4404,
        linear_team_id: "team_apply_instructions",
        linear_team_key: "API",
        default_branch: "main",
        clone_path: "/tmp/repos/apply-instructions"
      })

    {:ok, role} =
      Roles.create_role(scope, project, %{
        backend_id: backend.id,
        name: "Engineer",
        stage: :engineer,
        model: "claude-3-7-sonnet",
        system_prompt: "Old instructions"
      })

    %{project: project, role: role}
  end

  test "applies improved instructions with admin scope", %{role: role} do
    scope = Scope.for_user(%{admin: true})

    new_instructions = "Comprehensive revised system prompt instructions."

    assert {:ok, %Role{system_prompt: ^new_instructions}} =
             Roles.apply_improved_instructions(scope, role, new_instructions)

    assert {:ok, %Role{system_prompt: ^new_instructions}} = Roles.get_role(id: role.id)
  end

  test "applies improved instructions with system scope", %{role: role} do
    scope = Scope.for_system()

    revised = "System approved prompt."

    assert {:ok, %Role{system_prompt: ^revised}} =
             Roles.apply_improved_instructions(scope, role, revised)
  end

  test "returns not authorized for non-admin scope", %{role: role} do
    scope = Scope.for_user(%{admin: false})

    assert {:error, :not_authorized} =
             Roles.apply_improved_instructions(scope, role, "Blocked instructions")
  end

  test "returns not authorized for nil scope", %{role: role} do
    assert {:error, :not_authorized} =
             Roles.apply_improved_instructions(nil, role, "Blocked instructions")
  end
end
