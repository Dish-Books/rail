defmodule Rail.Roles do
  @moduledoc false

  use Rail.PermissionsDecorator

  alias Rail.Roles.Actions
  alias Rail.Roles.Schemas

  defdelegate list_roles(project_id), to: Actions.ListRoles

  defdelegate get_role(by), to: Actions.GetRole

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
end
