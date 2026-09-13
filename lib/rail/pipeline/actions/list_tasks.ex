defmodule Rail.Pipeline.Actions.ListTasks do
  @moduledoc false

  import Ecto.Query

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Lists tasks, filtered and preloaded as `opts` asks.
  """
  def list_tasks(opts \\ []) do
    Task
    |> from(as: :task)
    |> order_by(^Keyword.get(opts, :order_by, asc: :inserted_at))
    |> preload(^Keyword.get(opts, :preload, []))
    |> filter_project(opts[:project_id])
    |> filter_stage(opts[:stage])
    |> Repo.all()
  end

  defp filter_project(query, project_id) when is_binary(project_id) do
    where(query, [task: t], t.project_id == ^project_id)
  end

  defp filter_project(query, _all_projects), do: query

  defp filter_stage(query, nil), do: query

  defp filter_stage(query, stage) when is_atom(stage) do
    where(query, [task: t], t.stage == ^stage)
  end
end
