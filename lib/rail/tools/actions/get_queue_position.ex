defmodule Rail.Tools.Actions.GetQueuePosition do
  @moduledoc false

  import Ecto.Query

  alias Rail.Pipeline.Schemas.Run
  alias Rail.Repo
  alias Rail.Tools.Schemas.OsProcess

  @doc """
  Where `run` stands in the line for sandboxes: `{:ok, %{position: n, os_process: row}}`,
  1 being next to start, or `{:error, :not_waiting}` when it is not in line.

  One query: the run's waiting row by its run index, and its place counted over the
  `(status, queued_at)` index, which holds only the line.
  """
  def get_queue_position(%Run{id: run_id}) do
    ahead =
      from q in OsProcess,
        where:
          q.status == :waiting_for_resources and
            (q.queued_at < parent_as(:line).queued_at or
               (q.queued_at == parent_as(:line).queued_at and q.id <= parent_as(:line).id)),
        select: count()

    query =
      from p in OsProcess,
        as: :line,
        where: p.run_id == ^run_id and p.status == :waiting_for_resources,
        order_by: [desc: p.inserted_at],
        limit: 1,
        select: %{position: subquery(ahead), os_process: p}

    case Repo.one(query) do
      %{os_process: %OsProcess{}} = line -> {:ok, line}
      nil -> {:error, :not_waiting}
    end
  end
end
