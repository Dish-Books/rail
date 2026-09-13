defmodule Rail.Pipeline.Actions.ListRuns do
  @moduledoc false

  import Ecto.Query

  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Lists runs, filtered and preloaded as `opts` asks.

  `:project_id` reaches through the task each run belongs to, so a caller showing
  one project's work asks for runs and gets exactly those.
  """
  def list_runs(opts \\ []) do
    Run
    |> from(as: :run)
    |> order_by(^Keyword.get(opts, :order_by, asc: :inserted_at))
    |> preload(^Keyword.get(opts, :preload, []))
    |> filter_project(opts[:project_id])
    |> Repo.all()
  end

  defp filter_project(query, project_id) when is_binary(project_id) do
    query
    |> join(:inner, [run: r], t in Task, on: t.id == r.task_id, as: :task)
    |> where([task: t], t.project_id == ^project_id)
  end

  defp filter_project(query, _all_projects), do: query
end
