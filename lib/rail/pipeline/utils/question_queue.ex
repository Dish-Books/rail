defmodule Rail.Pipeline.Utils.QuestionQueue do
  @moduledoc """
  Helpers for the set of questions a task is parked on.

  A run can ask several things at once, so a blocked task holds a queue: every
  question is its own `Question` row, `task.question_id` names the one currently in
  front, and the stage only resumes once nothing pending is left. Answers accumulate
  as `:answered` rows with no `delivered_at` until that moment, then go back to the
  agent together.
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

  def pending_questions(_other), do: []

  @doc """
  Returns the question that should be in front of the human next, or `nil` when the
  queue has drained.
  """
  def next_pending_question(task_id) do
    task_id |> pending_questions() |> List.first()
  end

  @doc """
  Lists answers gathered during this blocked round: answered questions that have not
  been handed back to the agent yet, oldest first.
  """
  def undelivered_answers(task_id) when is_binary(task_id) do
    Repo.all(
      from q in Question,
        where: q.task_id == ^task_id and q.status == :answered and is_nil(q.delivered_at),
        order_by: [asc: q.answered_at, asc: q.inserted_at]
    )
  end

  def undelivered_answers(_other), do: []

  @doc """
  Stamps `questions` as delivered so the next blocked round starts from an empty slate.
  """
  def mark_delivered(questions, now \\ DateTime.utc_now()) do
    ids = Enum.map(questions, & &1.id)

    Repo.update_all(
      from(q in Question, where: q.id in ^ids),
      set: [delivered_at: now, updated_at: now]
    )

    :ok
  end

  @doc """
  Formats the answers of one blocked round into the comment the agent is resumed with.
  """
  def format_answers([%Question{} = question]) do
    "You asked: #{question.prompt}\nThe answer is: #{question.answer}"
  end

  def format_answers(questions) when is_list(questions) do
    body =
      questions
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {question, index} ->
        "#{index}. You asked: #{question.prompt}\n   The answer is: #{question.answer}"
      end)

    "You asked #{length(questions)} questions. Answers, in order:\n\n#{body}"
  end
end
