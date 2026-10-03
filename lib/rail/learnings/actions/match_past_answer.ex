defmodule Rail.Learnings.Actions.MatchPastAnswer do
  @moduledoc """
  The questions gate: whether a person already answered a question like this one, searched among decision rules from answers.
  """

  import Ecto.Query
  import Rail.Learnings.Utils.SearchLearnings

  alias Rail.Learnings.Clients.Vertex
  alias Rail.Learnings.Schemas.Learning
  alias Rail.Learnings.Schemas.Observation
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @answer 0.90
  @suggest 0.80

  @doc """
  Returns `{:answer, source}`, `{:suggestion, source}` or nil, `source` being `%{learning:, observation:}` with the past answer.
  """
  def match_past_answer(%Task{project_id: project_id}, %Question{prompt: prompt}) do
    scope = [project_id: project_id, statuses: [:active, :provisional], kind: :decision, source_kind: :answer]

    with [_embedded] <- search_learnings(scope ++ [embedded: true, limit: 1], nil),
         {:ok, embedding} <- Vertex.embed(prompt, "RETRIEVAL_QUERY"),
         [%Learning{similarity: similarity} = learning] when similarity >= @suggest <-
           search_learnings([{:limit, 1} | scope], embedding) do
      {if(similarity >= @answer, do: :answer, else: :suggestion), %{learning: learning, observation: source(learning)}}
    else
      _no_match -> nil
    end
  end

  defp source(%Learning{id: id}) do
    Repo.one(
      from o in Observation,
        where: o.learning_id == ^id and o.source_kind == :answer,
        order_by: [desc: o.inserted_at, desc: o.id],
        limit: 1,
        preload: [:actor, task: :issue]
    )
  end
end
