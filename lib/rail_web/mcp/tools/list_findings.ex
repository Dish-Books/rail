defmodule RailWeb.Mcp.Tools.ListFindings do
  @moduledoc """
  Lists what Review found on a ticket's task, newest round first: each finding's problem, where it is, its evidence,
  the reviewer's recommendation, the ruling and who made it, and the version decide_finding needs.
  """

  use Anubis.Server.Component, type: :tool, annotations: %{readOnlyHint: true}

  import RailWeb.Utils.McpErrorResponse
  import RailWeb.Utils.ReadMcpFindings

  alias Anubis.Server.Response
  alias RailWeb.Mcp.FindingJSON

  schema do
    field :identifier, {:required, :string}, description: "The ticket's identifier, such as RAIL-12."
  end

  @impl true
  def execute(%{identifier: identifier}, %{assigns: %{current_scope: scope}} = frame) do
    case read_mcp_findings(scope, identifier) do
      {:ok, assigns} -> {:reply, Response.json(Response.tool(), FindingJSON.index(assigns)), frame}
      {:error, reason} -> {:reply, mcp_error_response(reason), frame}
    end
  end
end
