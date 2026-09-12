defmodule Rail.Runs.Actions.ListRunEvents do
  @moduledoc false

  import Ecto.Query

  alias Rail.Repo
  alias Rail.Runs.Schemas.RunEvent

  @doc """
  Lists all run events for a run ordered by sequence.
  """
  def list_run_events(run_id, opts \\ []) do
    limit = Keyword.get(opts, :limit)

    query =
      from(e in RunEvent,
        where: e.run_id == ^run_id,
        order_by: [asc: e.seq]
      )

    query = if limit, do: limit(query, ^limit), else: query
    Repo.all(query)
  end
end
