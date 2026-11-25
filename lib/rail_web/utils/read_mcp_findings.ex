defmodule RailWeb.Utils.ReadMcpFindings do
  @moduledoc """
  Reads a ticket's findings the way the MCP finding tools answer with them, for `RailWeb.Mcp.FindingJSON`.
  """

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Users

  @doc """
  The ticket `identifier` names in the scope's projects, its task, the review round, the task's findings and the
  rulers' logins by id. Returns `{:error, {:issue_not_found, identifier}}`, `{:error, {:no_task, identifier}}`, or
  `{:error, :round_changed_during_read}` when a review round opened while it read.
  """
  def read_mcp_findings(scope, identifier) do
    case Issues.find_issue(scope, identifier, preload: [task: :issue]) do
      {:ok, %Issue{task: %Task{} = task} = issue} ->
        # Read on both sides of the list, so every version it gives names the round its findings came from.
        round = length(Pipeline.read_review(task))
        findings = Pipeline.list_findings(task)

        ids =
          for finding <- findings,
              id <- [finding.decided_by_id | Enum.map(finding.notes, & &1.by_id)],
              is_binary(id),
              uniq: true,
              do: id

        logins = scope |> Users.list_users_by_ids(ids) |> Map.new(&{&1.id, &1.login})

        if length(Pipeline.read_review(task)) == round,
          do: {:ok, %{issue: issue, task: task, round: round, findings: findings, logins: logins}},
          else: {:error, :round_changed_during_read}

      {:ok, %Issue{task: nil}} ->
        {:error, {:no_task, identifier}}

      {:error, :not_found} ->
        {:error, {:issue_not_found, identifier}}
    end
  end
end
