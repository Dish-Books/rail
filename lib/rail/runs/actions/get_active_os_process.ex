defmodule Rail.Runs.Actions.GetActiveOsProcess do
  @moduledoc false

  import Ecto.Query

  alias Rail.Repo
  alias Rail.Runs.Schemas.OsProcess

  @doc """
  Fetches the most recent live os process for a run or task ID, or `nil` when nothing is running.
  """
  def get_active_os_process(id) when is_binary(id) do
    Repo.one(
      from r in OsProcess,
        where: (r.run_id == ^id or r.task_id == ^id) and r.status in [:starting, :running],
        order_by: [desc: r.inserted_at],
        limit: 1
    )
  end
end
