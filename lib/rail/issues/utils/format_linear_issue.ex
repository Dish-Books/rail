defmodule Rail.Issues.Utils.FormatLinearIssue do
  @moduledoc """
  Reads a Linear issue, as the GraphQL API or a webhook sends it, into the
  attributes Rail keeps for it.
  """

  @doc """
  The issue attributes `node` describes. Where it belongs and who owns it are
  the caller's to add.
  """
  def format_linear_issue(%{} = node) do
    state = node["state"] || %{}

    %{
      external_id: node["id"],
      identifier: node["identifier"],
      title: node["title"],
      description: node["description"],
      priority: priority(node["priority"]),
      estimate: node["estimate"],
      state: state(state["type"]),
      state_name: state["name"],
      branch_name: node["branchName"],
      url: node["url"],
      completed_at: completed_at(node["completedAt"])
    }
  end

  # Linear sends milliseconds, but the column holds seconds and `insert_all`
  # writes the value without casting it, so it is truncated here.
  defp completed_at(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, at, _offset} -> DateTime.truncate(at, :second)
      {:error, _reason} -> nil
    end
  end

  defp completed_at(_not_completed), do: nil

  # Linear's 0 means "no priority set", which Rail keeps as its default.
  defp priority(1), do: :urgent
  defp priority(2), do: :high
  defp priority(3), do: :medium
  defp priority(4), do: :low
  defp priority(_unset), do: :medium

  defp state("triage"), do: :triage
  defp state("backlog"), do: :backlog
  defp state("unstarted"), do: :backlog
  defp state("started"), do: :in_progress
  defp state("completed"), do: :done
  defp state("canceled"), do: :canceled
  defp state("duplicate"), do: :duplicate
  defp state(_other), do: :backlog
end
