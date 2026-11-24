defmodule Rail.Initiatives.Actions.ListInitiatives do
  @moduledoc "The initiatives of the projects a scope can open, with their progress."

  import Ecto.Query
  import Rail.Initiatives.Utils.CountTickets

  alias Rail.Initiatives.Schemas.Initiative
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Options: `:project_id`, one id or a list, and `:sort`: `:expected` (soonest first, none last; the default), `:name`
  or `:progress` (most done first). Every order ends on name, then id.
  """
  def list_initiatives(%Scope{} = scope, opts \\ []) do
    Initiative
    |> where_projects(opts[:project_id])
    |> count_tickets(scope)
    |> order(Keyword.get(opts, :sort, :expected))
    |> preload(:project)
    |> Repo.all()
  end

  defp where_projects(query, nil), do: query
  defp where_projects(query, ids) when is_list(ids), do: where(query, [i], i.project_id in ^ids)
  defp where_projects(query, id) when is_binary(id), do: where(query, [i], i.project_id == ^id)

  defp order(query, :expected), do: order_by(query, [i], asc_nulls_last: i.expected_on, asc: i.name, asc: i.id)
  defp order(query, :name), do: order_by(query, [i], asc: i.name, asc: i.id)

  # An initiative with no counted tickets reads 0%, so it sorts with the others at 0.
  defp order(query, :progress) do
    order_by(query, [i, t],
      desc: fragment("COALESCE(count(?) FILTER (WHERE ? = 'done')::float / NULLIF(count(?), 0), 0)", t.id, t.state, t.id),
      asc: i.name,
      asc: i.id
    )
  end
end
