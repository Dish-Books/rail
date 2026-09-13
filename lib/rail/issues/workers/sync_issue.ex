defmodule Rail.Issues.Workers.SyncIssue do
  @moduledoc """
  Pushes a local issue change up to Linear.

  The job carries the names of the fields that actually changed and sends only
  those. Nothing is read back and nothing else is written, so an edit somebody
  made in Linear to a field this change did not touch is still there afterwards.
  Rail is not the owner of the ticket; it is one of two writers.
  """
  use Oban.Worker, queue: :issues, max_attempts: 5

  import Rail.Issues.Utils.TokenResolver

  alias Rail.Issues.Clients.Linear
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  @pushable [:title, :description, :priority, :estimate, :state]

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

  defp update_linear(%Project{} = project, %Issue{} = issue, attrs) do
    with {:ok, token, _identity} <- resolve_token(owner(issue), project),
         {:ok, _updated} <- Linear.update_issue(token, issue.external_id, attrs) do
      :ok
    end
  end

  # `state` is Rail's word for it; Linear wants the workflow state's own id.
  defp linear_attrs(%Issue{} = issue, %Project{} = project, fields) do
    fields
    |> Enum.map(&to_existing_field/1)
    |> Enum.filter(&(&1 in @pushable))
    |> Map.new(fn
      :state -> {:state_id, project.linear_state_ids[to_string(issue.state)]}
      field -> {field, Map.fetch!(issue, field)}
    end)
    |> Map.reject(fn {_field, value} -> is_nil(value) end)
  end

  defp to_existing_field(field) when is_atom(field), do: field

  defp to_existing_field(field) when is_binary(field) do
    String.to_existing_atom(field)
  rescue
    ArgumentError -> :unknown
  end

  defp owner(%Issue{owner_user_id: user_id}) when is_binary(user_id), do: %{id: user_id}
  defp owner(%Issue{}), do: nil
end
