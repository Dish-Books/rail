defmodule Rail.Learnings.Utils.SearchLearnings do
  @moduledoc """
  The one query rules are found with. With an embedding it ranks by cosine distance alone, leaving out unembedded rules;
  without one it lists newest first. A glob is matched in SQL, `**` and `*` as `%` and `?` as `_`.
  """

  import Ecto.Query
  import Pgvector.Ecto.Query

  alias Rail.Learnings.Schemas.Learning
  alias Rail.Learnings.Schemas.Observation
  alias Rail.Repo

  @kinds Learning.kinds()
  @roles Learning.roles()
  @source_kinds Observation.source_kinds()

  @doc """
  Returns the learnings `filters` keep, nearest `embedding` first with a `similarity`, or newest first without one. Filters: `:project_id`, `:ids`,
  `:statuses`, `:kind`, `:role`, `:auto`, `:pinned`, `:activated_since`, `:path`, `:source_kind`, `:embedded` and `:limit`.
  """
  def search_learnings(filters, embedding) when is_list(filters) do
    filters
    |> Enum.reduce(from(l in Learning, as: :learning), &filter/2)
    |> rank(embedding)
    |> limit(^Keyword.get(filters, :limit))
    |> Repo.all()
  end

  defp filter({:project_id, project_id}, query) when is_binary(project_id),
    do: where(query, [learning: l], l.project_id == ^project_id)

  defp filter({:project_id, ids}, query) when is_list(ids), do: where(query, [learning: l], l.project_id in ^ids)

  defp filter({:ids, ids}, query) when is_list(ids), do: where(query, [learning: l], l.id in ^ids)
  defp filter({:statuses, statuses}, query) when is_list(statuses), do: where(query, [learning: l], l.status in ^statuses)
  defp filter({:kind, kind}, query) when kind in @kinds, do: where(query, [learning: l], l.kind == ^kind)

  defp filter({:role, role}, query) when role in @roles do
    where(query, [learning: l], fragment("cardinality(?) = 0 OR ? = ANY(?)", l.roles, ^to_string(role), l.roles))
  end

  defp filter({:auto, true}, query), do: where(query, [learning: l], l.auto)
  defp filter({:pinned, true}, query), do: where(query, [learning: l], l.pinned)

  defp filter({:activated_since, %DateTime{} = since}, query), do: where(query, [learning: l], l.activated_at >= ^since)

  # Escapes LIKE's own wildcards first, so only the glob's become them; chr(63) is `?`.
  defp filter({:path, path}, query) when is_binary(path) do
    where(
      query,
      [learning: l],
      is_nil(l.path_glob) or
        fragment(
          "? LIKE replace(replace(replace(replace(replace(replace(?, '\\', '\\\\'), '%', '\\%'), '_', '\\_'), '**', '%'), '*', '%'), chr(63), '_')",
          ^path,
          l.path_glob
        )
    )
  end

  defp filter({:source_kind, kind}, query) when kind in @source_kinds do
    where(
      query,
      [learning: l],
      exists(from o in Observation, where: o.learning_id == parent_as(:learning).id and o.source_kind == ^kind)
    )
  end

  defp filter({:embedded, true}, query), do: where(query, [learning: l], not is_nil(l.embedding))
  defp filter({_name, _unset_or_limit}, query), do: query

  defp rank(query, nil) do
    order_by(query, [learning: l], desc: coalesce(l.retired_at, coalesce(l.activated_at, l.inserted_at)), desc: l.id)
  end

  defp rank(query, embedding) when is_list(embedding) do
    vector = Pgvector.new(embedding)

    query
    |> where([learning: l], not is_nil(l.embedding))
    |> order_by([learning: l], asc: cosine_distance(l.embedding, ^vector), asc: l.id)
    |> select_merge([learning: l], %{similarity: 1 - cosine_distance(l.embedding, ^vector)})
  end
end
