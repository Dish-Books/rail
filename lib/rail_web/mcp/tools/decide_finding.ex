defmodule RailWeb.Mcp.Tools.DecideFinding do
  @moduledoc """
  Rules one of a ticket's findings as you: fix, dont_fix or new_issue. It is saved, not sent: a new_issue waits for
  Send in Rail. Pass the version list_findings gave, so a ruling made since, or a new review round, is not overwritten.
  """

  use Anubis.Server.Component, type: :tool

  import RailWeb.Utils.McpErrorResponse
  import RailWeb.Utils.ReadMcpFindings

  alias Anubis.Server.Response
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Finding
  alias RailWeb.Mcp.FindingJSON

  schema do
    field :identifier, {:required, :string}, description: "The ticket's identifier, such as RAIL-12."
    field :key, {:required, :string}, description: "The finding's key, as list_findings gave it."
    field :decision, {:required, {:enum, ["fix", "dont_fix", "new_issue"]}}
    field :version, {:required, :string}, description: "The finding's version, as list_findings gave it."
  end

  @impl true
  def execute(
        %{identifier: identifier, key: key, decision: decision, version: version},
        %{assigns: %{current_scope: scope}} = frame
      ) do
    with {:ok, read} <- read_version(version),
         {:ok, %{findings: findings}} <- read_mcp_findings(scope, identifier),
         {:ok, finding} <- find_finding(findings, identifier, key),
         {:ok, _decided} <- Pipeline.decide_finding(scope, finding, decision(decision), read: read) do
      {:reply, read_back(scope, identifier, key), frame}
    else
      {:error, reason} -> {:reply, mcp_error_response(reason), frame}
    end
  end

  # The ruling committed before this read, so a read that fails says it is saved rather than that nothing was.
  defp read_back(scope, identifier, key) do
    case read_mcp_findings(scope, identifier) do
      {:ok, reread} ->
        decided = Enum.find(reread.findings, &(&1.key == key))
        Response.json(Response.tool(), FindingJSON.show(Map.put(reread, :finding, decided)))

      {:error, :round_changed_during_read} ->
        mcp_error_response(:ruled_round_changed)

      {:error, reason} ->
        mcp_error_response({:ruled_unread, reason})
    end
  end

  # The version came from Claude, so anything but `<round>@<timestamp>` is refused rather than crashed on.
  defp read_version(version) do
    with [round, at] <- String.split(version, "@", parts: 2),
         {round, ""} when round >= 0 <- Integer.parse(round),
         {:ok, updated_at, _offset} <- DateTime.from_iso8601(at) do
      {:ok, %{round: round, updated_at: updated_at}}
    else
      _unreadable -> {:error, {:invalid, :version, "is not one list_findings gave"}}
    end
  end

  defp find_finding(findings, identifier, key) do
    case Enum.find(findings, &(&1.key == key)) do
      %Finding{} = finding -> {:ok, finding}
      nil -> {:error, {:finding_not_found, identifier, key}}
    end
  end

  defp decision("fix"), do: :fix
  defp decision("dont_fix"), do: :skip
  defp decision("new_issue"), do: :new_issue
end
