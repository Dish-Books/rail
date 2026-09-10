defmodule Rail.Issues.Actions.ListIssues do
  @moduledoc false

  import Ecto.Query

  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope

  def list_issues(scope, project_or_opts \\ [])

  def list_issues(%Scope{system: true}, project_or_opts) do
    fetch_issues(project_or_opts)
  end

  def list_issues(%Scope{user: %{}}, project_or_opts) do
    fetch_issues(project_or_opts)
  end

  def list_issues(_scope, _project_or_opts), do: []

  def list_issues(%Scope{} = scope, %Project{id: project_id}, opts) when is_list(opts) do
    list_issues(scope, Keyword.put(opts, :project_id, project_id))
  end

  def list_issues(_scope, _project, _opts), do: []

  defp fetch_issues(%Project{id: project_id}) do
    fetch_issues(project_id: project_id)
  end

  defp fetch_issues(opts) when is_list(opts) do
    query =
      Issue
      |> maybe_filter_project(Keyword.get(opts, :project_id))
      |> maybe_filter_state(Keyword.get(opts, :state))
      |> maybe_filter_finished(Keyword.get(opts, :show_finished, false))
      |> maybe_preload(Keyword.get(opts, :preload))
      |> order_by([i], asc: i.inserted_at)

    Repo.all(query)
  end

  defp maybe_filter_project(query, nil), do: query
  defp maybe_filter_project(query, project_id), do: where(query, [i], i.project_id == ^project_id)

  defp maybe_filter_state(query, nil), do: query
  defp maybe_filter_state(query, state), do: where(query, [i], i.state == ^state)

  defp maybe_filter_finished(query, true), do: query
  defp maybe_filter_finished(query, false), do: where(query, [i], i.state not in [:done, :canceled])

  defp maybe_preload(query, nil), do: query
  defp maybe_preload(query, preloads), do: preload(query, ^preloads)
end
