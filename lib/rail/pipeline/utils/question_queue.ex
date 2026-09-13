defmodule Rail.Pipeline.Utils.QuestionQueue do
  @moduledoc """
  The questions a task is parked on.

  A run can ask several things at once, so a blocked task holds a queue: every
  question is its own `Question` row, and nothing the task is waiting for is
  resolved until the queue has drained.
  """

  import Ecto.Query

  alias Rail.Pipeline.Schemas.Question
  alias Rail.Repo

  @doc """
  Lists the task's still-unanswered questions, oldest first — the order they are
  offered to the human.
  """
  def pending_questions(task_id) when is_binary(task_id) do
    Repo.all(
      from q in Question,
        where: q.task_id == ^task_id and q.status == :pending,
        order_by: [asc: q.inserted_at, asc: q.id]
    )
  end
end
