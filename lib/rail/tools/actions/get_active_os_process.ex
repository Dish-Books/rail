defmodule Rail.Tools.Actions.GetActiveOsProcess do
  @moduledoc false

  import Ecto.Query

  alias Rail.Pipeline.Schemas.Run
  alias Rail.Repo
  alias Rail.Tools.Schemas.OsProcess

  @doc """
  Fetches the live OS process carrying `run`.

  Returns `{:error, :os_process_not_active}` when the run is not executing, which
  is an ordinary answer rather than a failure — a run spends most of its life that
  way.
  """
  def get_active_os_process(%Run{id: run_id}) do
    query =
      from p in OsProcess,
        where: p.run_id == ^run_id and p.status in [:starting, :running],
        order_by: [desc: p.inserted_at],
        limit: 1

    case Repo.one(query) do
      %OsProcess{} = os_process -> {:ok, os_process}
      nil -> {:error, :os_process_not_active}
    end
  end
end
