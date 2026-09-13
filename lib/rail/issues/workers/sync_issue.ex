defmodule Rail.Issues.Workers.SyncIssue do
  @moduledoc """
  Pushes a local issue change up to Linear.

  The job carries the names of the fields that actually changed and sends only
  those. Nothing is read back and nothing else is written, so an edit somebody
  made in Linear to a field this change did not touch is still there afterwards.
  Rail is not the owner of the ticket; it is one of two writers.
  """
  use Oban.Worker, queue: :issues, max_attempts: 5

  import Rail.Issues.Utils.LinearPriority

  alias Rail.Issues.Schemas.Issue
  alias Rail.Linear.Client, as: Linear
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  @pushable [:title, :description, :priority, :estimate, :state, :owner_user_id]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"issue_id" => issue_id, "fields" => fields}}) do
    case Repo.get(Issue, issue_id) do
      %Issue{} = issue -> push(Repo.preload(issue, :project), fields)
      nil -> :ok
    end
  end

  defp push(%Issue{project: %Project{} = project} = issue, fields) do
    case linear_attrs(issue, project, fields) do
      attrs when map_size(attrs) == 0 -> :ok
      attrs -> update_linear(project, issue, attrs)
    end
  end

  defp update_linear(%Project{} = project, %Issue{} = issue, input) do
    case Linear.update_issue(project, issue.external_id, input) do
      {:ok, %{"issueUpdate" => %{"success" => true}}} -> :ok
      {:ok, _not_updated} -> {:error, {:linear_mutation_failed, "issueUpdate"}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Linear names things its own way: a workflow state by its id, a priority by
  # its number, an assignee by their Linear user id. Unassigning is the one
  # change sent as a null.
  defp linear_attrs(%Issue{} = issue, %Project{} = project, fields) do
    fields
    |> Enum.map(&to_existing_field/1)
    |> Enum.filter(&(&1 in @pushable))
    |> Map.new(fn
      :state -> {"stateId", project.linear_state_ids[to_string(issue.state)]}
      :priority -> {"priority", linear_priority(issue.priority)}
      :owner_user_id -> {"assigneeId", issue |> Repo.preload(:owner_user) |> linear_assignee_id()}
      field -> {to_string(field), Map.fetch!(issue, field)}
    end)
    |> Map.reject(fn {field, value} -> is_nil(value) and field != "assigneeId" end)
  end

  defp linear_assignee_id(%Issue{owner_user: %{linear_user_id: linear_user_id}}), do: linear_user_id
  defp linear_assignee_id(%Issue{owner_user: nil}), do: nil

  defp to_existing_field(field) when is_atom(field), do: field

  defp to_existing_field(field) when is_binary(field) do
    String.to_existing_atom(field)
  rescue
    ArgumentError -> :unknown
  end
end
