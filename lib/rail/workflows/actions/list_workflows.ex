defmodule Rail.Workflows.Actions.ListWorkflows do
  @moduledoc false

  import Ecto.Query

  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Workflows.Schemas.Workflow

  @doc """
  Lists the workflows whose file is on their project's default branch, of the projects the scope can access, with
  their project, by project name and then path.

  Options: `:due`, a moment, keeps only the valid rows due by then, paused ones included, since a paused row
  still has each due time taken.
  """
  def list_workflows(%Scope{} = scope, opts) when is_list(opts) do
    Workflow
    |> join(:inner, [w], p in assoc(w, :project))
    |> where([w], is_nil(w.removed_at))
    |> then(&if(ids = Scope.project_ids(scope), do: where(&1, [w], w.project_id in ^ids), else: &1))
    |> filter_due(opts[:due])
    |> order_by([w, p], asc: p.name, asc: p.id, asc: w.path)
    |> preload([w, p], project: p)
    |> Repo.all()
    |> then(&{:ok, &1})
  end

  defp filter_due(query, nil), do: query
  defp filter_due(query, %DateTime{} = at), do: where(query, [w], w.next_run_at <= ^at)
end
