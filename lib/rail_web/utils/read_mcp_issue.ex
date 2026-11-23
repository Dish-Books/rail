defmodule RailWeb.Utils.ReadMcpIssue do
  @moduledoc """
  Reads a ticket the way the MCP tools answer with it in full, for `RailWeb.Mcp.IssueJSON.show/1`.
  """

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue

  @preload [:owner_user, :parent, :children, comments: [:author_user, replies: :author_user]]

  @doc """
  The ticket `identifier` names in the scope's projects, with what it shows loaded, its blockers and its cycle. Returns `{:error, {:issue_not_found, identifier}}` for one the person cannot open.
  """
  def read_mcp_issue(scope, identifier) do
    case Issues.find_issue(scope, identifier, preload: @preload) do
      {:ok, %Issue{project: project} = issue} ->
        {:ok, %{cycles: cycles}} = Issues.get_cycles(project)

        {:ok,
         %{
           issue: issue,
           blockers: Map.get(Issues.get_blockers([issue]), issue.id, %{blocked_by: [], blocks: []}),
           cycle: Enum.find(cycles, &(&1.id == issue.cycle_id))
         }}

      {:error, :not_found} ->
        {:error, {:issue_not_found, identifier}}
    end
  end
end
