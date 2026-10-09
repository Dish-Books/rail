defmodule Rail.Learnings.Actions.ListLearnings do
  @moduledoc """
  Lists rules for the page, `knowledge_search` and lookups by id. A query ranks by embedding alone,
  so an unembedded rule never answers one and a query that cannot be embedded is an error.
  """

  import Ecto.Query
  import Rail.Learnings.Utils.SearchLearnings

  alias Rail.Learnings.Clients.Vertex
  alias Rail.Learnings.Schemas.Learning
  alias Rail.Learnings.Schemas.Observation
  alias Rail.Repo

  @filters [:project_id, :ids, :statuses, :kind, :role, :auto, :activated_since, :path, :source_kind]

  @doc """
  Returns `{:ok, learnings}` with project and card figures, taking `search_learnings/2`'s filters, `:status`, `:query`,
  `:embedding` (the query's, already made), `:limit` (50 for a query, 100 otherwise) and `sources: true`;
  or `{:error, reason}` when the query cannot be embedded.
  """
  def list_learnings(opts \\ []) do
    filters =
      opts
      |> Keyword.take(@filters)
      |> Keyword.put_new(:statuses, opts[:status] && [opts[:status]])

    with {:ok, learnings} <- search(filters, text(opts[:query]), opts[:embedding], opts[:limit]) do
      learnings =
        learnings
        |> Repo.preload([:project, :approved_by])
        |> preload_sources(opts[:sources])
        |> put_figures()

      {:ok, learnings}
    end
  end

  defp search(filters, nil, _embedding, limit), do: {:ok, search_learnings([{:limit, limit || 100} | filters], nil)}

  defp search(filters, _query, embedding, limit) when is_list(embedding),
    do: {:ok, search_learnings([{:limit, limit || 50} | filters], embedding)}

  defp search(filters, query, nil, limit) do
    with {:ok, embedding} <- Vertex.embed(query, "RETRIEVAL_QUERY") do
      search(filters, query, embedding, limit)
    end
  end

  defp text(query) when is_binary(query) do
    case String.trim(query) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp text(_no_query), do: nil

  defp preload_sources(learnings, true) do
    Repo.preload(learnings,
      observations: from(o in Observation, order_by: [desc: o.inserted_at, desc: o.id], preload: [:actor, task: :issue])
    )
  end

  defp preload_sources(learnings, _no_sources), do: learnings

  defp put_figures([]), do: []

  # One query for every card, each figure a correlated count rather than a join,
  # since joining four one-to-manys multiplies their rows into each other.
  defp put_figures(learnings) do
    ids = Enum.map(learnings, & &1.id)

    figures =
      from(l in Learning,
        where: l.id in ^ids,
        select:
          {l.id,
           %{
             run_count:
               fragment("(SELECT count(DISTINCT r.run_id) FROM learning_retrievals r WHERE r.learning_id = ?)", l.id),
             suppressed_count: fragment("(SELECT count(*) FROM findings f WHERE f.suppressed_by_id = ?)", l.id),
             broken_count:
               fragment(
                 "(SELECT count(*) FROM findings f WHERE f.rule_id = ? AND f.suppressed_by_id IS NULL AND EXISTS (SELECT 1 FROM learning_retrievals r JOIN runs u ON u.id = r.run_id WHERE r.learning_id = f.rule_id AND u.task_id = f.task_id))",
                 l.id
               ),
             override_count:
               fragment(
                 "(SELECT count(*) FROM observations o WHERE o.learning_id = ? AND o.source_kind = 'override')",
                 l.id
               ),
             flagged:
               fragment(
                 "EXISTS (SELECT 1 FROM learning_proposals p WHERE p.learning_id = ? AND p.action = 'override' AND p.status = 'pending')",
                 l.id
               )
           }}
      )
      |> Repo.all()
      |> Map.new()

    Enum.map(learnings, &struct(&1, Map.fetch!(figures, &1.id)))
  end
end
