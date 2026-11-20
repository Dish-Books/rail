defmodule Rail.Support.Actions.ListIntercomWorkspaces do
  @moduledoc false

  import Ecto.Query

  alias Rail.Repo
  alias Rail.Support.Schemas.IntercomWorkspace

  @doc """
  Every workspace, by name, with the project it feeds; `project_id:` keeps those of one project or a list of them.
  """
  def list_intercom_workspaces(opts \\ []) when is_list(opts) do
    IntercomWorkspace
    |> filter_project(opts[:project_id])
    |> order_by([w], asc: w.name, asc: w.id)
    |> preload(:project)
    |> Repo.all()
  end

  defp filter_project(query, nil), do: query
  defp filter_project(query, ids) when is_list(ids), do: where(query, [w], w.project_id in ^ids)
  defp filter_project(query, id), do: where(query, [w], w.project_id == ^id)
end
