defmodule Rail.Tools.Actions.ListOsProcesses do
  @moduledoc false

  import Ecto.Query

  alias Rail.Repo
  alias Rail.Tools.Schemas.OsProcess

  @doc """
  Lists os processes matching criteria.
  """
  def list_os_processes(opts \\ []) do
    query = from(r in OsProcess, order_by: [desc: r.inserted_at])

    query =
      Enum.reduce(opts, query, fn
        {:run_id, run_id}, q -> where(q, [r], r.run_id == ^run_id)
        {:task_id, task_id}, q -> where(q, [r], r.task_id == ^task_id)
        {:status, status}, q -> where(q, [r], r.status == ^status)
        {:kind, kind}, q -> where(q, [r], r.kind == ^kind)
        _other, q -> q
      end)

    Repo.all(query)
  end
end
