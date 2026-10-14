defmodule Rail.Pipeline.Actions.CreateRound do
  @moduledoc """
  Starts a task's next round, numbered one past its latest.
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
      latest = Repo.one!(from r in Round, where: r.task_id == ^task_id, select: coalesce(max(r.number), 0))

      task |> Round.changeset(latest + 1) |> Repo.insert!()
    end)
  end
end
