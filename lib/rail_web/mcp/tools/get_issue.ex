defmodule RailWeb.Mcp.Tools.GetIssue do
  @moduledoc """
  Opens a ticket in full: its description, comments, parent, sub-issues and assignee, and the cycle and blockers of a
  Rail-tracked ticket.
  """

  use Anubis.Server.Component, type: :tool, annotations: %{readOnlyHint: true}

  import RailWeb.Utils.McpErrorResponse
  import RailWeb.Utils.ReadMcpIssue

  alias Anubis.Server.Response
  alias RailWeb.Mcp.IssueJSON

  schema do
    field :identifier, {:required, :string}, description: "The ticket's identifier, such as RAIL-12."
  end

  @impl true
  def execute(%{identifier: identifier}, %{assigns: %{current_scope: scope}} = frame) do
    case read_mcp_issue(scope, identifier) do
      {:ok, assigns} -> {:reply, Response.json(Response.tool(), IssueJSON.show(assigns)), frame}
      {:error, reason} -> {:reply, mcp_error_response(reason), frame}
    end
  end
end
