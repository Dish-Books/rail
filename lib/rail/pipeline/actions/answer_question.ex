defmodule Rail.Pipeline.Actions.AnswerQuestion do
  @moduledoc """
  Records the human's answer to one question the agent asked, replacing any earlier one.

  An answer can be changed, or given to a dismissed question, until `send_answers/1` sends the round.
  """

  alias Rail.Pipeline.Schemas.Question
  alias Rail.Repo

  @doc """
  Records `answer` against `question`.
  """
  def answer_question(%Question{delivered_at: nil, status: status} = question, answer)
      when status in [:pending, :answered, :dismissed] and is_binary(answer) do
    case String.trim(answer) do
      "" -> {:error, :empty_answer}
      trimmed -> record(question, trimmed)
    end
  end

  def answer_question(%Question{}, _answer), do: {:error, :already_sent}

  defp record(%Question{} = question, answer) do
    question
    |> Question.changeset(%{answer: answer, status: :answered, answered_at: DateTime.utc_now()})
    |> Repo.update()
  end
end
