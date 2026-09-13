defmodule Rail.Projects do
  @moduledoc false

  use Rail.PermissionsDecorator

  alias Rail.Projects.Actions

  @decorate can?(resource: :projects, action: :create)
  defdelegate create_project(scope, attrs), to: Actions.CreateProject

  defdelegate list_projects(), to: Actions.ListProjects

  defdelegate get_project(id), to: Actions.GetProject

  defdelegate get_linear_workspace(by), to: Actions.GetLinearWorkspace

  @decorate can?(resource: :projects, action: :update)
  defdelegate update_project(scope, project, attrs), to: Actions.UpdateProject
end
