defmodule Rail.Pipeline.Actions.ReadPlan do
  @moduledoc """
  Reads a task's plan: its first round, which holds the ticket, the implementation plan, the design option the plan
  is written for and, once a person approved it, when.
  """

  import Ecto.Query

  alias Rail.Pipeline.Schemas.Round
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Returns `task`'s first round, or `nil` when nothing of its plan is saved yet. Its `plan` is `nil` while only the
  ticket is saved, and its `approved_at` is `nil` until it is approved.
  """
  def read_plan(%Task{id: task_id}) do
    Repo.one(from r in Round, where: r.task_id == ^task_id and r.number == 1)
  end
end
