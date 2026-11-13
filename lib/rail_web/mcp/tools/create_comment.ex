defmodule RailWeb.Mcp.Tools.CreateComment do
  @moduledoc "Comments on a ticket as you, in its tracker."

  use Anubis.Server.Component, type: :tool

  import RailWeb.Utils.McpErrorResponse

  alias Anubis.Server.Response
  alias Rail.Issues

  schema do
    field :identifier, {:required, :string}, description: "The ticket's identifier, such as RAIL-12."
    field :body, {:required, :string}, description: "Markdown."
  end

  @impl true
  def execute(%{identifier: identifier, body: body}, %{assigns: %{current_scope: scope}} = frame) do
    with {:ok, issue} <- find(scope, identifier),
         body when body != "" <- String.trim(body),
         {:ok, comment} <- Issues.comment(scope, issue, %{body: body}) do
      data = %{comment: %{identifier: issue.identifier, body: comment.body, created_at: comment.inserted_at}}
      {:reply, Response.json(Response.tool(), data), frame}
    else
      "" -> {:reply, mcp_error_response(:blank_body), frame}
      {:error, reason} -> {:reply, mcp_error_response(reason), frame}
    end
  end

  defp find(scope, identifier) do
    case Issues.find_issue(scope, identifier) do
      {:ok, issue} -> {:ok, issue}
      {:error, :not_found} -> {:error, {:issue_not_found, identifier}}
    end
  end
end
