defmodule Rail.Pipeline.Actions.SendAnswers do
  @moduledoc """
  Hands a run the answers to everything it asked, as one message once nothing is open.

  A dismissed question travels with the answers, said plainly; a round with no answer at all is `dismiss_round/1`'s.
  An answer Rail took from a past one cites whose it was, and a round Rail answered whole is sent as Rail's.
  """

  import Ecto.Query
  import Rail.Pipeline.Utils.UnsentRound

  alias Rail.Learnings
  alias Rail.Learnings.Schemas.Observation
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Sends `run` the round it is parked on, from the scope's user.

  Returns `{:error, :questions_pending}` while anything it asked is open, `{:error, :nothing_to_send}`
  when there is no round, and `{:error, :nothing_answered}` when every question was dismissed.
  """
  def send_answers(%Scope{} = scope, %Run{} = run) do
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
        # A page open elsewhere hears nothing else when the message cannot go out.
        Phoenix.PubSub.broadcast(Rail.PubSub, "run:#{run.id}", {:run_changed, run.id})

        from = if Enum.all?(round, & &1.answered_by_rail), do: :past_answers
        text = format(round, citations(round))

        # A person's answers are learned from once they have gone out, since until then they can change.
        with {:ok, _delivery, _run} = sent <- Pipeline.send_message(scope, run, text, from: from) do
          answered = Enum.filter(round, &(&1.status == :answered and not &1.answered_by_rail))
          {:ok, _learned} = Learnings.record_corrections(Repo.get!(Task, run.task_id), answered)
          sent
        end
    end
  end

  defp mark_delivered(round) do
    now = DateTime.utc_now()

    Repo.update_all(
      from(q in Question, where: q.id in ^Enum.map(round, & &1.id)),
      set: [delivered_at: now, updated_at: now]
    )
  end

  # Whose past answer each of Rail's answers came from, the latest source of the rule it answered with.
  defp citations(round) do
    ids = for %Question{answered_by_rail: true, suggested_learning_id: id} <- round, is_binary(id), do: id
    {:ok, rules} = if ids == [], do: {:ok, []}, else: Learnings.list_learnings(ids: Enum.uniq(ids), sources: true)

    for rule <- rules, source = Enum.find(rule.observations, &(&1.source_kind == :answer)), into: %{} do
      on = if source.task, do: " on #{source.task.issue.identifier}", else: ""
      {rule.id, "#{Observation.actor_label(source)}'s answer#{on}, #{Calendar.strftime(source.inserted_at, "%b %-d")}"}
    end
  end

  defp format([%Question{} = question], citations) do
    "You asked: #{question.prompt}\n#{outcome(question, citations)}"
  end

  defp format(round, citations) do
    body =
      round
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {question, index} ->
        "#{index}. You asked: #{question.prompt}\n   #{outcome(question, citations)}"
      end)

    "You asked #{length(round)} questions. Answers, in order:\n\n#{body}"
  end

  defp outcome(%Question{status: :answered, answered_by_rail: true, answer: answer} = question, citations) do
    case Map.fetch(citations, question.suggested_learning_id) do
      {:ok, cited} -> "Answered by Rail from #{cited}: #{answer}"
      :error -> "Answered by Rail from a past answer: #{answer}"
    end
  end

  defp outcome(%Question{status: :answered, answer: answer}, _citations), do: "The answer is: #{answer}"
  defp outcome(%Question{status: :dismissed}, _citations), do: "Dismissed without an answer; carry on without it."
end
