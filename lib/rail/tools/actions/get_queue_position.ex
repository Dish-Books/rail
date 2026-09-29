defmodule Rail.Tools.Actions.GetQueuePosition do
  @moduledoc false

  import Ecto.Query

  alias Rail.Pipeline.Schemas.Run
  alias Rail.Repo
  alias Rail.Tools.Schemas.OsProcess

  @doc """
  Where `run` stands in the line for sandboxes: `{:ok, %{position: n, os_process: row}}`,
  1 being next to start, or `{:error, :not_waiting}` when it is not in line.
  """
  def get_queue_position(%Run{id: run_id}) do
    waiting =
      Repo.one(
        from p in OsProcess,
          where: p.run_id == ^run_id and p.status == :waiting_for_resources,
          order_by: [desc: p.inserted_at],
          limit: 1
      )

    case waiting do
      %OsProcess{queued_at: queued_at, id: id} = os_process ->
        ahead =
          Repo.aggregate(
            from(p in OsProcess,
              where:
                p.status == :waiting_for_resources and
                  (p.queued_at < ^queued_at or (p.queued_at == ^queued_at and p.id < ^id))
            ),
            :count
          )

        {:ok, %{position: ahead + 1, os_process: os_process}}

      nil ->
        {:error, :not_waiting}
    end
  end
end
