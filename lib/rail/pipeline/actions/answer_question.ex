defmodule Rail.Pipeline.Actions.AnswerQuestion do
  @moduledoc """
  Records the human's answer to one question the agent asked.

  Recording is all it does. The agent hears nothing until the human says so with
  `send_answers/1`, which is what lets somebody work through a batch — answering
  one, changing their mind about another, waving off a third — without the agent
  being resumed halfway through the thought.
  """

  alias Rail.Pipeline.Schemas.Question
  alias Rail.Repo

  @doc """
  Records `answer` against `question`.
  """
  def answer_question(%Question{status: :pending} = question, answer) when is_binary(answer) do
    case String.trim(answer) do
      "" -> {:error, :empty_answer}
      trimmed -> record(question, trimmed)
    end
  end

  def answer_question(%Question{}, _answer), do: {:error, :already_resolved}

  defp record(%Question{} = question, answer) do
    question
    |> Question.changeset(%{answer: answer, status: :answered, answered_at: DateTime.utc_now()})
    |> Repo.update()
  end
end
