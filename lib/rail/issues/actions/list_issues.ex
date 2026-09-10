defmodule Rail.Issues.Actions.ListIssues do
  @moduledoc false

  import Ecto.Query

  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope

  def list_issues(%Scope{system: true}, project_or_opts) do
    fetch_issues(project_or_opts)
  end

  def list_issues(%Scope{user: %{}}, project_or_opts) do
    fetch_issues(project_or_opts)
  end

  def list_issues(_scope, _project_or_opts), do: []

  defp fetch_issues(%Project{id: project_id}) do
    fetch_issues(project_id: project_id)
  end

  defp fetch_issues(opts) when is_list(opts) do
    query =
      Issue
      |> maybe_filter_project(Keyword.get(opts, :project_id))
      |> maybe_filter_state(Keyword.get(opts, :state))
      |> maybe_filter_finished(Keyword.get(opts, :show_finished, true))
      |> order_by([i], asc: i.inserted_at)

    Repo.all(query)
  end

  defp maybe_filter_project(query, nil), do: query
  defp maybe_filter_project(query, project_id), do: where(query, [i], i.project_id == ^project_id)

  defp maybe_filter_state(query, nil), do: query
  defp maybe_filter_state(query, state), do: where(query, [i], i.state == ^state)

  defp maybe_filter_finished(query, true), do: query
  defp maybe_filter_finished(query, false), do: where(query, [i], i.state not in [:done, :canceled])
end
