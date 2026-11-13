defmodule RailWeb.Mcp.Tools.UpdateIssue do
  @moduledoc """
  Changes a ticket. Send only the fields to change. A Linear or GitHub ticket takes only a status and an assignee here;
  its other fields are edited in its tracker.
  """

  use Anubis.Server.Component, type: :tool

  import RailWeb.Utils.McpErrorResponse
  import RailWeb.Utils.ReadMcpIssue

  alias Anubis.Server.Response
  alias Rail.Issues
  alias RailWeb.Mcp.IssueJSON

  # No defaults, so a field Claude leaves out is never sent as a change.
  schema do
    field :identifier, {:required, :string}, description: "The ticket's identifier, such as RAIL-12."
    field :title, :string
    field :description, :string, description: "Markdown. Replaces the whole description."
    field :priority, {:enum, ["urgent", "high", "medium", "low"]}
    field :estimate, :integer, description: "Points."
    field :parent, :string, description: "The identifier of its new parent, or empty for none."
    field :status, :string, description: "A status name, such as Todo or In Progress."
    field :cycle, :string, description: "`current`, `next`, a cycle's number, or `none`."
    field :assignee, :string, description: "A GitHub login, `me`, or empty for no one."
    field :blocked_by, {:list, :string}, description: "Every ticket that blocks this one, replacing the list."
  end

  @impl true
  def execute(%{identifier: identifier} = params, %{assigns: %{current_scope: scope}} = frame) do
    # A field sent as null is left out, as the description says, rather than cleared.
    attrs = params |> Map.delete(:identifier) |> Map.reject(fn {_field, value} -> is_nil(value) end)

    with {:ok, %{issue: issue}} <- read_mcp_issue(scope, identifier),
         {:ok, _issue} <- Issues.change_issue(scope, issue, attrs),
         {:ok, assigns} <- read_mcp_issue(scope, identifier) do
      {:reply, Response.json(Response.tool(), IssueJSON.show(assigns)), frame}
    else
      {:error, reason} -> {:reply, mcp_error_response(reason), frame}
    end
  end
end
