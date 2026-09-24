defmodule Rail.Projects do
  @moduledoc false

  use Rail.PermissionsDecorator

  alias Rail.Projects.Actions

  @decorate can?(resource: :projects, action: :create)
  defdelegate create_project(scope, attrs), to: Actions.CreateProject

  defdelegate list_projects(), to: Actions.ListProjects

  defdelegate get_project(id), to: Actions.GetProject

  defdelegate list_linear_workspaces(), to: Actions.ListLinearWorkspaces

  defdelegate get_linear_workspace(by), to: Actions.GetLinearWorkspace

  @decorate can?(resource: :linear_workspace, action: :create)
  defdelegate create_linear_workspace(scope, attrs), to: Actions.CreateLinearWorkspace

  @decorate can?(resource: :linear_workspace, action: :update)
  defdelegate update_linear_workspace(scope, workspace, attrs), to: Actions.UpdateLinearWorkspace

  @decorate can?(resource: :projects, action: :update)
  defdelegate update_project(scope, project, attrs), to: Actions.UpdateProject
end
