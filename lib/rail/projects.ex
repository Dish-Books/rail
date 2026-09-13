defmodule Rail.Projects do
  @moduledoc false

  use Rail.PermissionsDecorator

  alias Rail.Projects.Actions

  @decorate can?(resource: :projects, action: :create)
  defdelegate create_project(scope, attrs), to: Actions.CreateProject

  defdelegate list_projects(scope), to: Actions.ListProjects

  defdelegate get_project(scope, id), to: Actions.GetProject

  defdelegate get_project!(scope, id), to: Actions.GetProject

  @decorate can?(resource: :projects, action: :update)
  defdelegate update_project(scope, project, attrs), to: Actions.UpdateProject

  @decorate can?(resource: :linear_workspace, action: :upsert)
  defdelegate upsert_linear_workspace(scope, attrs), to: Actions.UpsertLinearWorkspace

  defdelegate get_linear_workspace(id_or_scope), to: Actions.GetLinearWorkspace
  defdelegate get_linear_workspace!(id_or_scope), to: Actions.GetLinearWorkspace
end
