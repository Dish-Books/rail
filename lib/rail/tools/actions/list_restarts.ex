defmodule Rail.Tools.Actions.ListRestarts do
  @moduledoc false

  import Ecto.Query

  alias Rail.Repo
  alias Rail.Tools.Schemas.Restart

  @doc """
  Lists restarts oldest first. `since:` keeps those Rail came back from at or after
  a time.
  """
  def list_restarts(opts \\ []) do
    query = from(r in Restart, order_by: [asc: r.inserted_at, asc: r.id])

    opts
    |> Enum.reduce(query, fn
      {:since, %DateTime{} = since}, q -> where(q, [r], r.started_at >= ^since)
      _other, q -> q
    end)
    |> Repo.all()
  end
end
