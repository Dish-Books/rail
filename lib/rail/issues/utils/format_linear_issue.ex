defmodule Rail.Issues.Utils.FormatLinearIssue do
  @moduledoc """
  Reads a Linear issue, as the GraphQL API or a webhook sends it, into the
  attributes Rail keeps for it.
  """

  @doc """
  The issue attributes `node` describes. Where it belongs and who owns it are
  the caller's to add. The cycle and the parent are left out when `node` says nothing of them.
  """
  def format_linear_issue(%{} = node) do
    state = node["state"] || %{}

    node
    |> cycle()
    |> Map.merge(parent(node))
    |> Map.merge(%{
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
      completed_at: seconds(node["completedAt"]),
      archived_at: seconds(node["archivedAt"]),
      external_updated_at: external_updated_at(node["updatedAt"])
    })
  end

  # The API nests each as an object, a webhook flattens it to an id.
  defp cycle(%{"cycle" => %{"id" => id}}), do: %{cycle_external_id: id}
  defp cycle(%{"cycle" => nil}), do: %{cycle_external_id: nil}
  defp cycle(%{"cycleId" => id}), do: %{cycle_external_id: id}
  defp cycle(_no_cycle_keys), do: %{}

  defp parent(%{"parent" => %{"id" => id}}), do: %{parent_external_id: id}
  defp parent(%{"parent" => nil}), do: %{parent_external_id: nil}
  defp parent(%{"parentId" => id}), do: %{parent_external_id: id}
  defp parent(_no_parent_keys), do: %{}

  # The column holds microseconds and `insert_all` writes the value without casting it.
  defp external_updated_at(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, %DateTime{microsecond: {usec, _precision}} = at, _offset} -> %{at | microsecond: {usec, 6}}
      {:error, _reason} -> nil
    end
  end

  defp external_updated_at(_missing), do: nil

  # Linear sends milliseconds, but the columns hold seconds and `insert_all`
  # writes the value without casting it, so it is truncated here.
  defp seconds(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, at, _offset} -> DateTime.truncate(at, :second)
      {:error, _reason} -> nil
    end
  end

  defp seconds(_missing), do: nil

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
