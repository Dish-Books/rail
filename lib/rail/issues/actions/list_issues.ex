defmodule Rail.Issues.Actions.ListIssues do
  @moduledoc false

  import Ecto.Query

  alias Rail.Issues.Schemas.Issue
  alias Rail.Repo

  @doc """
  Lists a page of issues along with how many match in all.

  Options: `:project_id`, `:state`, `:show_finished`, `:search`, `:priority`,
  `:limit`, `:offset` and `:preload`.

  Returns `%{issues: [...], total: n, priority_counts: %{priority => n}}`.
  `total` is every issue the filters match, not just the page. The priority
  counts leave `:priority` out, so each one says what picking it would show.
  """
  def list_issues(opts \\ []) when is_list(opts) do
    matching =
      Issue
      |> filter_project(opts[:project_id])
      |> filter_state(opts[:state])
      |> filter_finished(Keyword.get(opts, :show_finished, false))
      |> filter_search(opts[:search])

    priority_counts =
      matching
      |> group_by([i], i.priority)
      |> select([i], {i.priority, count(i.id)})
      |> Repo.all()
      |> Map.new()

    issues =
      matching
      |> filter_priority(opts[:priority])
      |> order_by([i], asc: i.inserted_at, asc: i.id)
      |> limit_to(opts[:limit])
      |> offset_by(opts[:offset])
      |> preload(^Keyword.get(opts, :preload, []))
      |> Repo.all()

    %{issues: issues, total: total(priority_counts, opts[:priority]), priority_counts: priority_counts}
  end

  defp filter_project(query, nil), do: query
  defp filter_project(query, project_id), do: where(query, [i], i.project_id == ^project_id)

  defp filter_state(query, nil), do: query
  defp filter_state(query, state), do: where(query, [i], i.state == ^state)

  defp filter_finished(query, true), do: query
  defp filter_finished(query, false), do: where(query, [i], i.state not in [:done, :canceled])

  defp filter_search(query, search) when is_binary(search) do
    case String.trim(search) do
      "" ->
        query

      term ->
        pattern = "%" <> String.replace(term, ~r/[\\%_]/, "\\\\\\0") <> "%"
        where(query, [i], ilike(i.title, ^pattern) or ilike(i.identifier, ^pattern))
    end
  end

  defp filter_search(query, _none), do: query

  defp filter_priority(query, nil), do: query
  defp filter_priority(query, priority), do: where(query, [i], i.priority == ^priority)

  defp limit_to(query, nil), do: query
  defp limit_to(query, limit), do: limit(query, ^limit)

  defp offset_by(query, nil), do: query
  defp offset_by(query, offset), do: offset(query, ^offset)

  defp total(priority_counts, nil), do: priority_counts |> Map.values() |> Enum.sum()
  defp total(priority_counts, priority), do: Map.get(priority_counts, priority, 0)
end
