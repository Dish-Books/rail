defmodule Rail.Roles do
  @moduledoc false

  use Rail.PermissionsDecorator

  alias Rail.Roles.Actions
  alias Rail.Roles.Schemas

  defdelegate canonical_stages(), to: Schemas.Role
  defdelegate list_roles(scope, project_id), to: Actions.ListRoles

  @decorate can?(resource: :roles, action: :view)
  defdelegate get_role(scope, id), to: Actions.GetRole

  defdelegate get_role!(scope, id), to: Actions.GetRole
  defdelegate role_for_stage(project_id, stage), to: Actions.RoleForStage

  @decorate can?(resource: :roles, action: :view)
  defdelegate role_for_stage(scope, project_id, stage), to: Actions.RoleForStage

  defdelegate role_for_stage!(project_id, stage), to: Actions.RoleForStage
  defdelegate role_for_stage!(scope, project_id, stage), to: Actions.RoleForStage

  @decorate can?(resource: :roles, action: :manage)
  defdelegate create_role(scope, project_or_id, attrs), to: Actions.CreateRole

  @decorate can?(resource: :roles, action: :manage)
  defdelegate update_role(scope, role, attrs), to: Actions.UpdateRole

  @decorate can?(resource: :roles, action: :manage)
  defdelegate delete_role(scope, role), to: Actions.DeleteRole

  @decorate can?(resource: :roles, action: :manage)
  defdelegate copy_roles(scope, target_project_or_id, source_project_id), to: Actions.CopyRoles

  @decorate can?(resource: :roles, action: :manage)
  defdelegate copy_roles(scope, target_project_or_id, source_project_id, opts), to: Actions.CopyRoles

  @decorate can?(resource: :roles, action: :view)
  defdelegate recent_finished_runs(scope, role_id), to: Actions.RecentFinishedRuns

  @decorate can?(resource: :roles, action: :view)
  defdelegate recent_finished_runs(scope, role_id, opts), to: Actions.RecentFinishedRuns

  defdelegate build_meta_prompt(role, sources), to: Actions.BuildMetaPrompt
  defdelegate parse_proposal(output, role_id, chosen_model, current_prompt, sources), to: Actions.ParseProposal
  defdelegate parse_proposal(output, role_id, chosen_model, current_prompt, sources, usage), to: Actions.ParseProposal

  @decorate can?(resource: :roles, action: :manage)
  defdelegate improve_role(scope, role, chosen_model), to: Actions.ImproveRole

  @decorate can?(resource: :roles, action: :manage)
  defdelegate improve_role(scope, role, chosen_model, opts), to: Actions.ImproveRole

  @decorate can?(resource: :roles, action: :manage)
  defdelegate apply_improved_instructions(scope, role, proposed_instructions),
    to: Actions.ApplyImprovedInstructions
end
