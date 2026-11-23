defmodule Rail.Issues.Actions.GetBlockers do
  @moduledoc false

  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Tracker
  alias Rail.Projects.Schemas.Project

  @doc """
  What blocks each of `issues`, their projects loaded, and what each blocks, by issue id. An entry is
  `%{issue: issue, in_project: true}`, open ones first.
  """
  def get_blockers(issues) when is_list(issues) do
    issues
    |> Enum.uniq_by(& &1.id)
    |> Enum.group_by(& &1.project_id)
    |> Enum.flat_map(fn {_project_id, [%Issue{project: %Project{} = project} | _rest] = grouped} ->
      {:ok, found} = Tracker.get_issue_relations(project, Enum.map(grouped, & &1.id))
      Enum.to_list(found)
    end)
    |> Map.new(fn {issue_id, related} ->
      {issue_id, %{blocked_by: entries(related.blocked_by), blocks: entries(related.blocks)}}
    end)
  end

  # A relation is always between two issues of one project, so every entry is in the project.
  defp entries(issues) do
    issues
    |> Enum.map(&%{issue: &1, in_project: true})
    |> Enum.sort_by(&{Issue.finished_state?(&1.issue.state), &1.issue.identifier})
  end
end
