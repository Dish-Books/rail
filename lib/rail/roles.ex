defmodule Rail.Roles do
  @moduledoc false

  alias Rail.Roles.Actions

  defdelegate list_roles(scope, project_id), to: Actions.ListRoles
  defdelegate get_role(scope, id), to: Actions.GetRole
  defdelegate get_role!(scope, id), to: Actions.GetRole
  defdelegate role_for_stage(project_id, stage), to: Actions.RoleForStage
  defdelegate role_for_stage(scope, project_id, stage), to: Actions.RoleForStage
  defdelegate role_for_stage!(project_id, stage), to: Actions.RoleForStage
  defdelegate role_for_stage!(scope, project_id, stage), to: Actions.RoleForStage
  defdelegate create_role(scope, project_or_id, attrs), to: Actions.CreateRole
  defdelegate update_role(scope, role, attrs), to: Actions.UpdateRole
  defdelegate delete_role(scope, role), to: Actions.DeleteRole
  defdelegate export_roles(scope, project_id), to: Actions.ExportRoles
  defdelegate import_roles(scope, project_or_id, roles_data), to: Actions.ImportRoles
  defdelegate import_roles(scope, project_or_id, roles_data, opts), to: Actions.ImportRoles
  defdelegate copy_roles(scope, target_project_or_id, source_project_id), to: Actions.CopyRoles
  defdelegate copy_roles(scope, target_project_or_id, source_project_id, opts), to: Actions.CopyRoles
  defdelegate recent_finished_runs(scope, role_id), to: Actions.RecentFinishedRuns
  defdelegate recent_finished_runs(scope, role_id, opts), to: Actions.RecentFinishedRuns
  defdelegate build_meta_prompt(role, sources), to: Actions.BuildMetaPrompt
  defdelegate parse_proposal(output, role_id, chosen_model, current_prompt, sources), to: Actions.ParseProposal
  defdelegate parse_proposal(output, role_id, chosen_model, current_prompt, sources, usage), to: Actions.ParseProposal
  defdelegate improve_role(scope, role, chosen_model), to: Actions.ImproveRole
  defdelegate improve_role(scope, role, chosen_model, opts), to: Actions.ImproveRole

  defdelegate apply_improved_instructions(scope, role, proposed_instructions),
    to: Actions.ApplyImprovedInstructions
end
