defmodule Rail.Pipeline.Actions.DismissQuestion do
  @moduledoc """
  Waves off an agent question, open or answered, until its round is sent.

  Like answering, this only records. The agent is told the question was dismissed
  when the round goes back, which is `send_answers/1`'s job.
  """

  alias Rail.Pipeline.Schemas.Question
  alias Rail.Repo

  @doc """
  Dismisses `question`.
  """
  def dismiss_question(%Question{delivered_at: nil} = question) do
    question
    |> Question.changeset(%{status: :dismissed})
    |> Repo.update()
  end

  def dismiss_question(%Question{}), do: {:error, :already_sent}
end
