defmodule Rail.Pipeline.Actions.ListRunEvents do
  @moduledoc false

  import Ecto.Query

  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.RunEvent
  alias Rail.Repo

  @doc """
  Lists all run events for a run ordered by sequence.
  """
  def list_run_events(%Run{id: run_id}, opts \\ []) do
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
