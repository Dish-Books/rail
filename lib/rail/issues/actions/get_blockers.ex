defmodule Rail.Issues.Actions.GetBlockers do
  @moduledoc false

  import Ecto.Query

  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Tracker
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  @doc """
  What blocks each of `issues`, their projects loaded, and what each blocks, as a map from external id to
  `%{blocked_by: entries, blocks: entries}`. An entry is `%{issue: issue, in_project: boolean}`, open ones first,
  then by identifier; one Rail does not hold in the same project carries no title. A project whose tracker fails
  adds nothing.
  """
  def get_blockers(issues) when is_list(issues) do
    relations =
      issues
      |> Enum.uniq_by(& &1.id)
      |> Enum.group_by(& &1.project_id)
      |> Enum.flat_map(fn {_project_id, [%Issue{project: %Project{} = project} | _rest] = grouped} ->
        case Tracker.tracker(project).get_issue_relations(project, Enum.map(grouped, & &1.external_id)) do
          {:ok, found} -> Enum.map(found, fn {external_id, related} -> {external_id, project.id, related} end)
          {:error, _reason} -> []
        end
      end)

    related_ids =
      for {_external_id, _project_id, related} <- relations,
          %Issue{} = issue <- related.blocked_by ++ related.blocks,
          uniq: true,
          do: issue.external_id

    held = held(related_ids)

    Map.new(relations, fn {external_id, project_id, related} ->
      {external_id,
       %{
         blocked_by: entries(related.blocked_by, project_id, held),
         blocks: entries(related.blocks, project_id, held)
       }}
    end)
  end

  defp held([]), do: %{}

  defp held(external_ids) do
    from(i in Issue, where: i.external_id in ^external_ids, select: {i.external_id, {i.id, i.project_id}})
    |> Repo.all()
    |> Map.new()
  end

  # Only a title from the project being shown may reach the page.
  defp entries(issues, project_id, held) do
    issues
    |> Enum.map(fn issue ->
      case held[issue.external_id] do
        {id, ^project_id} -> %{issue: %{issue | id: id, project_id: project_id}, in_project: true}
        _elsewhere -> %{issue: %{issue | title: nil}, in_project: false}
      end
    end)
    |> Enum.sort_by(&{Issue.finished_state?(&1.issue.state), &1.issue.identifier})
  end
end
