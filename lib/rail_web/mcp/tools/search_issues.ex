defmodule RailWeb.Mcp.Tools.SearchIssues do
  @moduledoc """
  Finds a project's tickets by meaning, finished and archived ones included: the ten nearest the query. Use it to see
  whether something is already tracked.
  """

  use Anubis.Server.Component, type: :tool, annotations: %{readOnlyHint: true}

  import RailWeb.Utils.McpErrorResponse

  alias Anubis.Server.Response
  alias Rail.Issues
  alias Rail.Projects
  alias RailWeb.Mcp.IssueJSON

  schema do
    field :project, {:required, :string}, description: "A project's key or name, from list_projects."
    field :query, {:required, :string}, description: "The problem or idea, described in a sentence."
  end

  @impl true
  def execute(%{project: project, query: query}, %{assigns: %{current_scope: scope}} = frame) do
    with {:ok, project} <- Projects.find_project(scope, project),
         {:ok, issues} <- Issues.search_issues(project.id, query) do
      {:reply, Response.json(Response.tool(), IssueJSON.index(%{issues: issues})), frame}
    else
      {:error, {:not_found, _keys} = reason} -> {:reply, mcp_error_response(reason), frame}
      # Never "nothing matched" when the search could not run: Claude told that would file a duplicate.
      {:error, _unembeddable} -> {:reply, mcp_error_response(:search_unavailable), frame}
    end
  end
end
