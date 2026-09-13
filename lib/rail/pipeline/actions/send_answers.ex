defmodule Rail.Pipeline.Actions.SendAnswers do
  @moduledoc """
  Hands a run the answers to everything it asked.

  A run ends by asking its whole batch, so the human works through the batch and
  the whole round goes back as one message — never once per answer. A question the
  human waved off travels with the answers, said plainly, so the agent knows it
  was seen and left alone rather than still waiting.

  Nothing goes anywhere while something is still pending: this is the button the
  human presses when they are done, and being done is the precondition.
  """

  import Ecto.Query

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Repo
  alias Rail.Runs.Schemas.Run

  @doc """
  Sends `run` the round it is parked on.

  Returns `{:error, :questions_pending}` while anything it asked is unanswered,
  and `{:error, :nothing_to_send}` when there is no round to hand back.
  """
  def send_answers(%Run{} = run) do
    with :ok <- nothing_pending(run),
         [_first | _rest] = round <- resolved_round(run) do
      mark_delivered(round)
      Pipeline.send_message(run, format(round))
    else
      {:error, reason} -> {:error, reason}
      [] -> {:error, :nothing_to_send}
    end
  end

  defp nothing_pending(%Run{id: run_id}) do
    if Repo.exists?(from q in Question, where: q.run_id == ^run_id and q.status == :pending) do
      {:error, :questions_pending}
    else
      :ok
    end
  end

  # Everything settled during this parked round, in the order it was asked.
  defp resolved_round(%Run{id: run_id}) do
    Repo.all(
      from q in Question,
        where: q.run_id == ^run_id and q.status in [:answered, :dismissed] and is_nil(q.delivered_at),
        order_by: [asc: q.inserted_at, asc: q.id]
    )
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
