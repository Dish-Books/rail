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

  defdelegate list_slack_workspaces(), to: Actions.ListSlackWorkspaces

  defdelegate get_slack_workspace(by), to: Actions.GetSlackWorkspace

  @decorate can?(resource: :slack_workspace, action: :create)
  defdelegate create_slack_workspace(scope, attrs), to: Actions.CreateSlackWorkspace

  @decorate can?(resource: :slack_workspace, action: :update)
  defdelegate update_slack_workspace(scope, workspace, attrs), to: Actions.UpdateSlackWorkspace

  defdelegate get_slack_channel(by), to: Actions.GetSlackChannel

  defdelegate list_slack_channels(project), to: Actions.ListSlackChannels

  @decorate can?(resource: :projects, action: :update)
  defdelegate set_slack_channels(scope, project, channels), to: Actions.SetSlackChannels
end
