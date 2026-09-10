defmodule Rail.Projects do
  @moduledoc false

  alias Rail.Projects.Actions

  defdelegate create_project(scope, attrs), to: Actions.CreateProject
  defdelegate list_projects(scope), to: Actions.ListProjects
  defdelegate get_project(scope, id), to: Actions.GetProject
  defdelegate get_project!(scope, id), to: Actions.GetProject
  defdelegate update_project(scope, project, attrs), to: Actions.UpdateProject
  defdelegate upsert_linear_workspace(scope, attrs), to: Actions.UpsertLinearWorkspace
  defdelegate get_linear_workspace(id_or_scope), to: Actions.GetLinearWorkspace
  defdelegate get_linear_workspace!(id_or_scope), to: Actions.GetLinearWorkspace
end
