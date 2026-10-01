defmodule Rail.Pipeline.Actions.SendAnswers do
  @moduledoc """
  Hands a run the answers to everything it asked, as one message once nothing is open.

  A dismissed question travels with the answers, said plainly; a round with no answer at all is `dismiss_round/1`'s.
  """

  import Ecto.Query
  import Rail.Pipeline.Utils.UnsentRound

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Repo

  @doc """
  Sends `run` the round it is parked on.

  Returns `{:error, :questions_pending}` while anything it asked is open, `{:error, :nothing_to_send}`
  when there is no round, and `{:error, :nothing_answered}` when every question was dismissed.
  """
  def send_answers(%Run{} = run) do
    round = unsent_round(run)

    cond do
      Enum.any?(round, &(&1.status == :pending)) ->
        {:error, :questions_pending}

      round == [] ->
        {:error, :nothing_to_send}

      Enum.all?(round, &(&1.status == :dismissed)) ->
        {:error, :nothing_answered}

      true ->
        mark_delivered(round)
        Pipeline.send_message(run, format(round))
    end
  end

  defp mark_delivered(round) do
    now = DateTime.utc_now()

    Repo.update_all(
      from(q in Question, where: q.id in ^Enum.map(round, & &1.id)),
      set: [delivered_at: now, updated_at: now]
    )
  end

  defp format([%Question{} = question]) do
    "You asked: #{question.prompt}\n#{outcome(question)}"
  end

  defp format(round) do
    body =
      round
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {question, index} ->
        "#{index}. You asked: #{question.prompt}\n   #{outcome(question)}"
      end)

    "You asked #{length(round)} questions. Answers, in order:\n\n#{body}"
  end

  defp outcome(%Question{status: :answered, answer: answer}), do: "The answer is: #{answer}"
  defp outcome(%Question{status: :dismissed}), do: "Dismissed without an answer; carry on without it."
end
