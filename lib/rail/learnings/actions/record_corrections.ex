defmodule Rail.Learnings.Actions.RecordCorrections do
  @moduledoc """
  Turns the corrections a person sent into provisional rules the same day, each source once, so a resend adds nothing.
  An answer taken from the past answer Rail suggested joins that rule instead of making another.
  """

  import Ecto.Query
  import Rail.Learnings.Utils.BroadcastLearningsChanged
  import Rail.Learnings.Utils.EnqueueEmbedding
  import Rail.Learnings.Utils.InsertObservations

  alias Rail.Learnings.Schemas.Learning
  alias Rail.Learnings.Schemas.Observation
  alias Rail.Pipeline.Schemas.DiffComment
  alias Rail.Pipeline.Schemas.QaFinding
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.ReviewFinding
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Records `records`, diff comments, Fix findings and answered questions of
  `task`. Returns `{:ok, learnings}`, the provisional rules it added.
  """
  def record_corrections(%Task{id: task_id, project_id: project_id}, records) when is_list(records) do
    suggested = suggested_answers(records)

    {:ok, {observations, learnings}} =
      Repo.transaction(fn ->
        observations =
          insert_observations(project_id, Enum.map(records, &Map.put(observation(&1, suggested), :task_id, task_id)))

        sources = Map.new(records, &{source_id(&1), &1})

        learnings =
          for %Observation{learning_id: nil} = observation <- observations do
            learning = insert_learning(project_id, Map.fetch!(sources, observation.source_id), observation)
            observation |> Ecto.Changeset.change(learning_id: learning.id) |> Repo.update!()
            learning
          end

        enqueue_embedding(learnings)
        {observations, learnings}
      end)

    if observations != [], do: broadcast_learnings_changed(project_id)
    {:ok, learnings}
  end

  defp source_id(%{id: id}), do: id

  # The answer each suggestion offered, the rule as it reads now, so one taken as offered is told apart from one rewritten.
  defp suggested_answers(records) do
    ids = for %Question{suggested_learning_id: id} <- records, is_binary(id), do: id

    from(l in Learning, where: l.id in ^ids, select: {l.id, l.rule})
    |> Repo.all()
    |> Map.new()
  end

  defp observation(%DiffComment{} = comment, _suggested) do
    %{
      source_kind: :diff_comment,
      source_id: comment.id,
      actor_id: comment.user_id,
      text: comment.body,
      excerpt: block(comment)
    }
  end

  defp observation(%ReviewFinding{} = finding, _suggested) do
    %{
      source_kind: :review_finding,
      source_id: finding.id,
      actor_id: finding.decided_by_id,
      text: finding.title,
      excerpt: finding.detail
    }
  end

  defp observation(%QaFinding{} = finding, _suggested) do
    %{
      source_kind: :qa_finding,
      source_id: finding.id,
      actor_id: finding.decided_by_id,
      text: finding.title,
      excerpt: finding.observed || finding.detail
    }
  end

  defp observation(%Question{} = question, suggested) do
    taken = question.suggested_learning_id && Map.get(suggested, question.suggested_learning_id) == question.answer

    %{
      source_kind: :answer,
      source_id: question.id,
      actor_id: question.answered_by_id,
      text: question.prompt,
      excerpt: question.answer,
      learning_id: if(taken, do: question.suggested_learning_id)
    }
  end

  defp insert_learning(project_id, source, %Observation{} = observation) do
    %Learning{project_id: project_id, status: :provisional}
    |> Learning.changeset(rule(source, observation))
    |> Repo.insert!()
  end

  defp rule(%DiffComment{} = comment, _observation) do
    %{
      kind: :convention,
      roles: [:engineer, :review],
      rule: clip(comment.body),
      why: "From a diff comment on #{comment.path}:\n\n#{block(comment)}"
    }
  end

  defp rule(%ReviewFinding{} = finding, _observation) do
    where = if finding.file, do: " on #{finding.file}", else: ""

    %{
      kind: :convention,
      roles: [:engineer, :review],
      rule: clip(finding.title),
      why: Enum.join(Enum.reject(["Raised in review#{where} and sent to be fixed.", finding.detail], &is_nil/1), "\n\n")
    }
  end

  defp rule(%QaFinding{} = finding, _observation) do
    %{
      kind: :convention,
      roles: [:engineer, :qa],
      rule: clip(finding.title),
      why: Enum.join(Enum.reject(["Raised by QA and sent to be fixed.", finding.detail], &is_nil/1), "\n\n")
    }
  end

  defp rule(%Question{} = question, _observation) do
    %{kind: :decision, roles: [], rule: clip(question.answer), why: "The answer when asked: #{question.prompt}"}
  end

  defp block(%DiffComment{context_text: context}) when is_binary(context) and context != "", do: context
  defp block(%DiffComment{line_text: line}), do: line

  defp clip(text), do: String.slice(text, 0, 2_000)
end
