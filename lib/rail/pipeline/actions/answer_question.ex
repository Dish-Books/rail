defmodule Rail.Pipeline.Actions.AnswerQuestion do
  @moduledoc """
  Records the human's answer to one question the agent asked, replacing any earlier one.

  An answer can be changed, or given to a dismissed question, until `send_answers/1` sends the round.
  """

  alias Rail.Pipeline.Schemas.Question
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Records `answer` against `question` as the scope's user.
  """
  def answer_question(%Scope{} = scope, %Question{delivered_at: nil, status: status} = question, answer)
      when status in [:pending, :answered, :dismissed] and is_binary(answer) do
    case String.trim(answer) do
      "" -> {:error, :empty_answer}
      trimmed -> record(scope, question, trimmed)
    end
  end

  def answer_question(%Scope{}, %Question{}, _answer), do: {:error, :already_sent}

  defp record(%Scope{} = scope, %Question{} = question, answer) do
    question
    |> Question.changeset(%{
      answer: answer,
      status: :answered,
      answered_at: DateTime.utc_now(),
      answered_by_id: scope.user && scope.user.id
    })
    |> Repo.update()
  end
end
