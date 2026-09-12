defmodule Rail.Pipeline.Actions.DismissQuestion do
  @moduledoc """
  Waves off a pending agent question: the human saw it and is not answering it.

  Like answering, this only records. The agent is told the question was dismissed
  when the round goes back, which is `send_answers/1`'s job.
  """

  alias Rail.Pipeline.Schemas.Question
  alias Rail.Repo

  @doc """
  Dismisses `question`.
  """
  def dismiss_question(%Question{status: :pending} = question) do
    question
    |> Question.changeset(%{status: :dismissed})
    |> Repo.update()
  end

  def dismiss_question(%Question{}), do: {:error, :already_resolved}
end
