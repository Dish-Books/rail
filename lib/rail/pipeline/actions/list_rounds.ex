defmodule Rail.Pipeline.Actions.ListRounds do
  @moduledoc """
  The rounds a task has been through, each with its plan as it stands.
  """

  import Ecto.Query

  alias Rail.Pipeline.Schemas.Round
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Lists every round of `task`, oldest first.
  """
  def list_rounds(%Task{id: task_id}) do
    Repo.all(from r in Round, where: r.task_id == ^task_id, order_by: [asc: r.number])
  end
end
