defmodule Rail.Tools.Actions.ListOsProcesses do
  @moduledoc false

  import Ecto.Query

  alias Rail.Repo
  alias Rail.Tools.Schemas.OsProcess

  @doc """
  Lists os processes matching criteria, newest first.

  `status:` takes one status or a list, `ended_after:` keeps those that ended since
  a time, `sandboxed: true` those holding a reservation, `preload:` loads what each
  belongs to, and `order: :queue` sorts the way the line is walked, oldest first.
  """
  def list_os_processes(opts \\ []) do
    # Ids are time-ordered, so they settle two rows written in the same microsecond.
    query = from(r in OsProcess, order_by: [desc: r.inserted_at, desc: r.id])

    query =
      Enum.reduce(opts, query, fn
        {:run_id, run_id}, q -> where(q, [r], r.run_id == ^run_id)
        {:task_id, task_id}, q -> where(q, [r], r.task_id == ^task_id)
        {:status, statuses}, q when is_list(statuses) -> where(q, [r], r.status in ^statuses)
        {:status, status}, q -> where(q, [r], r.status == ^status)
        {:kind, kind}, q -> where(q, [r], r.kind == ^kind)
        {:ended_after, %DateTime{} = since}, q -> where(q, [r], r.ended_at >= ^since)
        {:sandboxed, true}, q -> where(q, [r], not is_nil(r.reserved_cpus))
        {:preload, preloads}, q -> preload(q, ^preloads)
        {:order, :queue}, q -> q |> exclude(:order_by) |> order_by([r], asc: r.queued_at, asc: r.id)
        _other, q -> q
      end)

    Repo.all(query)
  end
end
