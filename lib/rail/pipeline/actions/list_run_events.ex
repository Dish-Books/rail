defmodule Rail.Pipeline.Actions.ListRunEvents do
  @moduledoc false

  import Ecto.Query

  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.RunEvent
  alias Rail.Repo

  @doc """
  Lists a run's events in sequence.

  `opts` takes `:limit`, and `:order` - `:desc` with a limit is how a caller asks
  for the newest few rather than reading a long pass's whole log to see the end
  of it.
  """
  def list_run_events(%Run{id: run_id}, opts \\ []) do
    limit = Keyword.get(opts, :limit)
    order = Keyword.get(opts, :order, :asc)

    query = from(e in RunEvent, where: e.run_id == ^run_id, order_by: [{^order, e.seq}])
    query = if limit, do: limit(query, ^limit), else: query

    Repo.all(query)
  end
end
