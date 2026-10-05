defmodule Rail.Pipeline.Actions.ListRunEvents do
  @moduledoc false

  import Ecto.Query

  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.RunEvent
  alias Rail.Repo

  @doc """
  Lists a run's events in sequence, or several runs' in one query, ordered by when each run
  started and then by sequence.

  `opts` takes `:limit`, and `:order` - `:desc` with a limit is how a caller asks
  for the newest few rather than reading a long pass's whole log to see the end
  of it.
  """
  def list_run_events(run_or_runs, opts \\ [])

  def list_run_events(%Run{id: run_id}, opts) do
    limit = Keyword.get(opts, :limit)
    order = Keyword.get(opts, :order, :asc)

    query = from(e in RunEvent, where: e.run_id == ^run_id, order_by: [{^order, e.seq}])
    query = if limit, do: limit(query, ^limit), else: query

    Repo.all(query)
  end

  def list_run_events([], _opts), do: []

  def list_run_events(runs, _opts) when is_list(runs) do
    ids = Enum.map(runs, fn %Run{id: id} -> id end)

    Repo.all(
      from e in RunEvent,
        join: r in Run,
        on: r.id == e.run_id,
        where: e.run_id in ^ids,
        order_by: [asc: r.started_at, asc: r.id, asc: e.seq]
    )
  end
end
