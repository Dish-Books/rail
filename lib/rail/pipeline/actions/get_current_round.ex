defmodule Rail.Pipeline.Actions.GetCurrentRound do
  @moduledoc """
  The round a task is in: its latest, whatever state that round has reached.
  """

  import Ecto.Query

  alias Rail.Pipeline.Schemas.Round
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Gets the latest round of `task`. Returns `{:ok, round}`, or `{:error, :not_found}` before its first.
  """
  def get_current_round(%Task{id: task_id}) do
    case Repo.one(from r in Round, where: r.task_id == ^task_id, order_by: [desc: r.number], limit: 1) do
      %Round{} = round -> {:ok, round}
      nil -> {:error, :not_found}
    end
  end
end
