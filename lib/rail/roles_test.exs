defmodule Rail.RolesTest do
  use Rail.DataCase, async: true

  alias Rail.Roles
  alias Rail.Roles.RoleInstructionProposal
  alias Rail.Roles.RoleRunRecord
  alias Rail.Roles.Schemas.Role
  alias Rail.Scope

  test "defdelegates for role CRUD operations" do
    scope = Scope.for_user(%{admin: true})
    project = create_test_project()

    assert {:ok, %Role{id: role_id, name: "Delegated Role"}} =
             Roles.create_role(scope, project, %{
               name: "Delegated Role",
               model: "claude-3-7-sonnet",
               system_prompt: "Test prompt"
             })

    assert {:ok, %Role{id: ^role_id} = role} = Roles.get_role(scope, role_id)
    assert %Role{id: ^role_id} = Roles.get_role!(scope, role_id)
    assert [%Role{id: ^role_id}] = Roles.list_roles(scope, project.id)

    assert {:ok, %Role{name: "Updated Delegated"}} =
             Roles.update_role(scope, role, %{
               name: "Updated Delegated"
             })

    assert {:ok, %Role{}} = Roles.delete_role(scope, role)
  end

  test "defdelegates for stage binding lookups" do
    scope = Scope.for_user(%{admin: true})
    project = create_test_project()

    %Role{id: role_id} =
      create_test_role(
        project_id: project.id,
        stage: :engineer,
        name: "Stage Bound Role"
      )

    assert {:ok, %Role{id: ^role_id}} = Roles.role_for_stage(scope, project.id, :engineer)
    assert {:ok, %Role{id: ^role_id}} = Roles.role_for_stage(project.id, :engineer)
    assert %Role{id: ^role_id} = Roles.role_for_stage!(scope, project.id, :engineer)
    assert %Role{id: ^role_id} = Roles.role_for_stage!(project.id, :engineer)
  end

  test "defdelegates for export, import, and copy" do
    scope = Scope.for_user(%{admin: true})
    source = create_test_project()
    target = create_test_project()

    create_test_role(
      project_id: source.id,
      stage: :product,
      name: "Source Product",
      system_prompt: "System instructions"
    )

    assert {:ok, exported} = Roles.export_roles(scope, source.id)
    assert length(exported) == 1

    assert {:ok, [%Role{name: "Source Product"}]} =
             Roles.copy_roles(scope, target, source.id)

    assert {:ok, [%Role{name: "Source Product"}]} =
             Roles.copy_roles(scope, target, source.id, replace_all: true)

    new_project = create_test_project()

    assert {:ok, [%Role{name: "Source Product"}]} =
             Roles.import_roles(scope, new_project, exported)

    assert {:ok, [%Role{name: "Source Product"}]} =
             Roles.import_roles(scope, new_project, exported, replace_all: true)
  end

  test "defdelegates for history digest, prompt building, proposal parsing, and improve flow" do
    scope = Scope.for_user(%{admin: true})
    role = create_test_role(system_prompt: "Current prompt")

    create_test_role_run(
      role_id: role.id,
      status: :finished,
      output: "Run finished output"
    )

    records = Roles.recent_finished_runs(scope, role.id)
    assert length(records) == 1
    assert [%RoleRunRecord{}] = Roles.recent_finished_runs(scope, role.id, limit: 1)

    meta_prompt = Roles.build_meta_prompt(role, records)
    assert meta_prompt =~ role.name

    proposal_output = """
    Proposal analysis.
    <<<INSTRUCTIONS>>>
    Improved prompt here.
    <<<END INSTRUCTIONS>>>
    """

    assert {:ok, %RoleInstructionProposal{proposed: "Improved prompt here."}} =
             Roles.parse_proposal(
               proposal_output,
               role.id,
               "claude-3-7-sonnet",
               role.system_prompt,
               records
             )

    assert {:ok, %RoleInstructionProposal{proposed: "Improved prompt here."}} =
             Roles.parse_proposal(
               proposal_output,
               role.id,
               "claude-3-7-sonnet",
               role.system_prompt,
               records,
               %{"input_tokens" => 10}
             )

    mock_runner = fn _dir, _improver_role, _opts ->
      {:ok, proposal_output, %{}}
    end

    assert {:ok, %RoleInstructionProposal{}} =
             Roles.improve_role(scope, role, "claude-3-7-sonnet", runner: mock_runner)

    assert {:ok, %Role{system_prompt: "Improved prompt here."}} =
             Roles.apply_improved_instructions(scope, role, "Improved prompt here.")
  end
end
