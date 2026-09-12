defmodule Rail.Pipeline.Utils.DeliverResolvedRound do
  @moduledoc """
  Hands one blocked round back to the agent that asked it.

  A run ends by asking its whole batch, so the human works through the batch and the
  round goes back as one message on the run that asked — never once per answer. A
  question the human waved off travels with the answers, said plainly, so the agent
  knows it was seen and left alone rather than still waiting.

  Answering the last of the batch and dismissing the last of it both land here: what
  matters is that nothing is pending any more.
  """

  import Ecto.Query
  import Rail.Pipeline.Utils.SendRunMessage

  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Runs.Schemas.Run

  @doc """
  Sends the round `task` just finished back on the run that asked it.

  Returns `{:error, :no_run}` when the round has nothing left to resume.
  """
  def deliver_resolved_round(%Task{} = task) do
    round = resolved_round(task.id)

    case run_that_asked(round) do
      %Run{} = run ->
        mark_delivered(round)
        send_run_message(run, format_round(round))

      nil ->
        {:error, :no_run}
    end
  end

  # Everything settled during this parked round, in the order it was asked.
  defp resolved_round(task_id) do
    Repo.all(
      from q in Question,
        where: q.task_id == ^task_id and q.status in [:answered, :dismissed] and is_nil(q.delivered_at),
        order_by: [asc: q.inserted_at, asc: q.id]
    )
  end

  # A question carries the run that asked it, so the round goes straight back there.
  defp run_that_asked(round) do
    round
    |> Enum.reverse()
    |> Enum.find_value(&Repo.get(Run, &1.run_id))
  end

  defp mark_delivered(round) do
    now = DateTime.utc_now()

    Repo.update_all(
      from(q in Question, where: q.id in ^Enum.map(round, & &1.id)),
      set: [delivered_at: now, updated_at: now]
    )
  end

  defp format_round([%Question{} = question]) do
    "You asked: #{question.prompt}\n#{outcome(question)}"
  end

  defp format_round(round) do
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
