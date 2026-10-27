defmodule Rail.Pipeline.Actions.CreateRound do
  @moduledoc """
  Starts a task's next round, numbered one past its latest, with the ticket and the design as the round before
  left them, so the latest round always holds the whole of what the plan stands on.
  """

  import Ecto.Query

  alias Rail.Pipeline.Schemas.Round
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Creates the next round of `task`. Returns `{:ok, round}`.
  """
  def create_round(%Task{id: task_id} = task) do
    Repo.transaction(fn ->
      # Two starts racing for the same task take the next number one after the other.
      Repo.one!(from t in Task, where: t.id == ^task_id, select: t.id, lock: "FOR UPDATE")
      latest = Repo.one(from r in Round, where: r.task_id == ^task_id, order_by: [desc: r.number], limit: 1)

      task |> Round.changeset(latest) |> Repo.insert!()
    end)
  end
end
