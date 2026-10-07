defmodule Rail.Issues.Utils.CalculateGithubState do
  @moduledoc """
  Reads the Rail state of a GitHub issue, as the REST API or a webhook sends it.
  """

  import Rail.Issues.Utils.GithubIssueLabels

  @doc """
  Closed wins over any label. An open issue is in the furthest state its labels name, and in the
  backlog when they name none, since an issue filed on GitHub is accepted work.
  """
  def calculate_github_state(%{"state" => "closed"} = issue) do
    case issue["state_reason"] do
      "not_planned" -> :canceled
      "duplicate" -> :duplicate
      _completed -> :done
    end
  end

  def calculate_github_state(%{} = issue) do
    names = Enum.map(issue["labels"] || [], & &1["name"])

    github_issue_labels()
    |> Enum.filter(&(&1.state && &1.name in names))
    |> List.last(%{state: :backlog})
    |> Map.fetch!(:state)
  end
end
