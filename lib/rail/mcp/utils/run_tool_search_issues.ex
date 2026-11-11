defmodule Rail.Mcp.Utils.RunToolSearchIssues do
  @moduledoc """
  Searches the role's project's tickets by meaning, for an agent checking whether something is already tracked.
  It takes the role, not a task, since a triage pass has none; a missing query or a search that cannot run answers in a sentence.
  """

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Roles.Schemas.Role

  @doc "Returns the ten tickets of `role`'s project nearest `arguments[\"query\"]`, one line each."
  def run_tool_search_issues(%Role{} = role, %{"query" => query}, _opts) when is_binary(query) do
    if String.trim(query) == "",
      do: run_tool_search_issues(role, %{}, []),
      else: search(role, query)
  end

  def run_tool_search_issues(%Role{}, _arguments, _opts) do
    {:ok, "search_issues needs a `query`: the problem, described in a sentence. Nothing was searched."}
  end

  defp search(%Role{project_id: project_id}, query) do
    case Issues.search_issues(project_id, query) do
      {:ok, []} ->
        {:ok, "No ticket in this project can be searched by meaning yet."}

      {:ok, issues} ->
        {:ok,
         Enum.map_join(issues, "\n", fn %Issue{} = issue ->
           "- `#{issue.identifier}` #{issue.title} · #{Issue.calculate_status_name(issue)}"
         end)}

      # Never "nothing matched": an agent told that would draft a duplicate.
      {:error, _unembeddable} ->
        {:ok, "Ticket search is unavailable right now. Nothing was searched."}
    end
  end
end
