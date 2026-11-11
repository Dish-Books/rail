defmodule Rail.Issues.Actions.ListIssues do
  @moduledoc false

  import Ecto.Query
  import Rail.Issues.Utils.CycleIssues

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Lists a page of issues, most recently updated first, along with how many
  match in all.

  Options: `:project_id` (one id or a list), `:owner_user_id`, `:cycle_id` (the tracker's id for a cycle of those projects,
  Rail's own for a Rail-tracked one, or a list), `:state`, `:show_finished`, `:search`, `:completed_after`, `:archived`,
  `:priority`, `:testing`, `:limit`, `:offset` and `:preload`.

  With `:cycle_id`, each issue is filtered and counted as its cycle holds it, so one a cycle held when it closed counts in
  the state it closed in. Each comes back live, with the cycle's state and status name in `cycle_state` and
  `cycle_state_name`.

  `testing: true` narrows to the testing queue, archived tickets included, oldest Done first.

  An issue archived in its tracker is left out unless a task holds it, or
  `archived: true` asks for every one.

  Returns `%{issues: [...], total: n, priority_counts: %{priority => n}}`.
  `total` is every issue the filters match, not just the page. The priority
  counts leave `:priority` out, so each one says what picking it would show.
  """
  def list_issues(opts \\ []) when is_list(opts) do
    matching =
      opts[:project_id]
      |> from_cycle(opts[:cycle_id])
      |> filter_project(opts[:project_id])
      |> filter_owner(opts[:owner_user_id])
      |> filter_state(opts[:state])
      |> filter_finished(Keyword.get(opts, :show_finished, opts[:testing] == true))
      |> filter_search(opts[:search])
      |> filter_completed_after(opts[:completed_after])
      |> filter_archived(Keyword.get(opts, :archived, opts[:testing] == true))
      |> filter_testing(opts[:testing])

    priority_counts =
      matching
      |> group_by([i], i.priority)
      |> select([i], {i.priority, count(i.id)})
      |> Repo.all()
      |> Map.new()

    issues =
      matching
      |> filter_priority(opts[:priority])
      |> order_issues(opts[:testing])
      |> limit_to(opts[:limit])
      |> offset_by(opts[:offset])
      |> select_live(opts[:cycle_id])
      |> Repo.all()
      # Not a query preload, which would apply to the cycle's reading that `select_live/2` no longer selects.
      |> Repo.preload(Keyword.get(opts, :preload, []))

    %{issues: issues, total: total(priority_counts, opts[:priority]), priority_counts: priority_counts}
  end

  defp filter_project(query, nil), do: query
  defp filter_project(query, project_ids) when is_list(project_ids), do: where(query, [i], i.project_id in ^project_ids)
  defp filter_project(query, project_id), do: where(query, [i], i.project_id == ^project_id)

  defp filter_owner(query, nil), do: query
  defp filter_owner(query, user_id), do: where(query, [i], i.owner_user_id == ^user_id)

  defp from_cycle(_project_id, nil), do: from(i in Issue)
  defp from_cycle(project_id, cycle_id), do: from(i in cycle_issues(List.wrap(project_id), List.wrap(cycle_id)))

  defp filter_state(query, nil), do: query
  defp filter_state(query, state), do: where(query, [i], i.state == ^state)

  defp filter_finished(query, true), do: query
  defp filter_finished(query, false), do: where(query, [i], i.state not in ^Issue.finished_states())

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

  defp filter_completed_after(query, nil), do: query

  defp filter_completed_after(query, %DateTime{} = after_at) do
    where(query, [i], i.completed_at >= ^after_at)
  end

  defp filter_archived(query, true), do: query

  defp filter_archived(query, false),
    do: where(query, [i], is_nil(i.archived_at) or i.id in subquery(from(t in Task, select: t.issue_id)))

  defp filter_testing(query, true), do: where(query, [i], i.state == :done and i.testing_state in ^[:waiting, :testing])

  defp filter_testing(query, _off), do: query

  defp filter_priority(query, nil), do: query
  defp filter_priority(query, priority), do: where(query, [i], i.priority == ^priority)

  defp order_issues(query, true), do: order_by(query, [i], asc: i.completed_at, asc: i.id)
  defp order_issues(query, _off), do: order_by(query, [i], desc: i.updated_at, desc: i.id)

  defp limit_to(query, nil), do: query
  defp limit_to(query, limit), do: limit(query, ^limit)

  defp offset_by(query, nil), do: query
  defp offset_by(query, offset), do: offset(query, ^offset)

  defp select_live(query, nil), do: query

  defp select_live(query, _cycle_id) do
    from([i] in query,
      join: live in Issue,
      on: live.id == i.id,
      select: merge(live, %{cycle_state: i.state, cycle_state_name: i.state_name})
    )
  end

  defp total(priority_counts, nil), do: priority_counts |> Map.values() |> Enum.sum()
  defp total(priority_counts, priority), do: Map.get(priority_counts, priority, 0)
end
