defmodule Rail.Issues.Utils.FormatGithubIssue do
  @moduledoc """
  Reads a GitHub issue, as the REST API or a webhook sends it, into the attributes Rail keeps for it.
  """

  import Rail.Issues.Utils.CalculateGithubState
  import Rail.Issues.Utils.GithubIssueLabels

  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects.Schemas.Project

  @doc """
  The issue attributes `issue` describes in `project`. Who owns it is the caller's to add.
  """
  def format_github_issue(%Project{key: key}, %{"number" => number} = issue) do
    state = calculate_github_state(issue)
    names = Enum.map(issue["labels"] || [], & &1["name"])

    %{
      tracker: :github,
      external_id: issue["node_id"],
      number: number,
      identifier: "#{key}##{number}",
      title: issue["title"],
      description: issue["body"],
      priority: Enum.find_value(github_issue_labels(), :medium, &(&1.name in names and &1.priority)),
      state: state,
      state_name: Issue.state_label(state),
      # GitHub names no branch, so Rail does, after the identifier, as Linear's `eng-301-title`.
      branch_name: "#{key}-#{number}-#{slug(issue["title"])}" |> String.downcase() |> String.trim("-"),
      url: issue["html_url"],
      completed_at: if(state == :done, do: timestamp(issue["closed_at"], :second)),
      external_updated_at: timestamp(issue["updated_at"], :microsecond)
    }
  end

  defp slug(title) do
    title |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.slice(0, 40) |> String.trim("-")
  end

  # `insert_all` writes values without casting them, so each is cut to its column's precision here.
  defp timestamp(value, :second) do
    {:ok, at, _offset} = DateTime.from_iso8601(value)
    DateTime.truncate(at, :second)
  end

  defp timestamp(value, :microsecond) do
    {:ok, %DateTime{microsecond: {usec, _precision}} = at, _offset} = DateTime.from_iso8601(value)
    %{at | microsecond: {usec, 6}}
  end
end
