defmodule Rail.Issues.Tracker.Linear do
  @moduledoc """
  Issues kept in Linear. Writes go as the workspace, except a ticket or comment opened for a
  user who linked Linear, which goes as them. Linear reports its changes through its webhook.
  """
  @behaviour Rail.Issues.Tracker

  import Ecto.Query
  import Rail.Issues.Utils.FormatLinearIssue
  import Rail.Issues.Utils.LinearPriority
  import Rail.Issues.Utils.UpsertLinearComment

  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Workers.LinearSync
  alias Rail.Linear.Client, as: Linear
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Users.Schemas.User

  @impl true
  def create_issue(_scope, %Project{linear_team_id: nil}, _attrs), do: {:error, :linear_team_not_found}

  # Opened as the scope's user, or as the workspace when there is no user or they never linked Linear.
  def create_issue(scope, %Project{linear_team_id: team_id} = project, %{state: state} = attrs) do
    input =
      Map.reject(
        %{
          "teamId" => team_id,
          "title" => attrs[:title],
          "description" => attrs[:description],
          "priority" => linear_priority(attrs[:priority]),
          "estimate" => attrs[:estimate],
          "parentId" => attrs[:parent] && attrs[:parent].external_id,
          "assigneeId" => linear_user_id(attrs[:owner_user_id]),
          "stateId" => project.linear_state_ids[Atom.to_string(state)]
        },
        fn {_key, value} -> is_nil(value) end
      )

    case Linear.create_issue(project, input, as: scope) do
      {:ok, %{"issueCreate" => %{"success" => true, "issue" => linear_issue}}} ->
        state_name = get_in(linear_issue, ["state", "name"]) || Issue.state_label(state)
        {:ok, Map.merge(format_linear_issue(linear_issue), %{state: state, state_name: state_name})}

      {:ok, _not_created} ->
        {:error, {:linear_mutation_failed, "issueCreate"}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Linear names things its own way: a workflow state by its id, a priority by its number, an
  # assignee by their Linear user id. Unassigning is the one change sent as a null. An estimate
  # goes in a mutation of its own after the rest, since a team whose scale refuses it, or that
  # has estimates off, would otherwise refuse the whole change.
  @impl true
  def update_issue(%Issue{project: %Project{} = project} = issue, fields, _previous_owner) do
    {estimate, rest} =
      fields
      |> Map.new(fn
        :state -> {"stateId", project.linear_state_ids[to_string(issue.state)]}
        :priority -> {"priority", linear_priority(issue.priority)}
        :owner_user_id -> {"assigneeId", issue.owner_user && issue.owner_user.linear_user_id}
        field -> {to_string(field), Map.fetch!(issue, field)}
      end)
      |> Map.reject(fn {field, value} -> is_nil(value) and field != "assigneeId" end)
      |> Map.split(["estimate"])

    with :ok <- update_linear(project, issue, rest), do: update_linear(project, issue, estimate)
  end

  # In Progress and In Review share Linear's "started" type, so In Review can only be told apart
  # by its name. Judged against the live state: somebody may have moved the ticket further by hand.
  @impl true
  def advance_issue(%Issue{project: %Project{} = project} = issue, target) do
    with {:ok, %{"issue" => %{"state" => current, "team" => %{"states" => %{"nodes" => states}}}}} <-
           Linear.issue_workflow(project, issue.external_id) do
      wanted =
        case target do
          :in_progress ->
            states |> Enum.filter(&(&1["type"] == "started")) |> Enum.min_by(& &1["position"], fn -> nil end)

          :in_review ->
            Enum.find(states, &(&1["type"] == "started" and String.downcase(&1["name"]) == "in review"))

          :done ->
            states |> Enum.filter(&(&1["type"] == "completed")) |> Enum.min_by(& &1["position"], fn -> nil end)
        end

      cond do
        is_nil(wanted) -> :ok
        calculate_rank(wanted) <= calculate_rank(current) -> :ok
        true -> update_linear(project, issue, %{"stateId" => wanted["id"]})
      end
    end
  end

  @impl true
  def create_comment(scope, %Issue{} = issue, body, parent) do
    project = Repo.get(Project, issue.project_id)

    input =
      Map.reject(
        %{"issueId" => issue.external_id, "body" => body, "parentId" => parent && parent.external_id},
        &is_nil(elem(&1, 1))
      )

    case Linear.create_comment(project, input, as: scope) do
      {:ok, %{"commentCreate" => %{"success" => true, "comment" => node}}} -> upsert_linear_comment(node)
      {:ok, _not_created} -> {:error, {:linear_mutation_failed, "commentCreate"}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def canonical_identifier(%Project{}, identifier), do: {:ok, identifier}

  # Rail keeps only the project's own team's tickets.
  @impl true
  def fetch_issue(%Project{linear_team_id: team_id} = project, identifier) do
    case Linear.issue(project, identifier) do
      {:ok, %{"issue" => %{"team" => %{"id" => ^team_id}} = node}} when is_binary(team_id) ->
        {:ok, Map.put(format_linear_issue(node), :owner_user_id, owner_user_id(get_in(node, ["assignee", "id"])))}

      {:ok, _elsewhere} ->
        {:error, :not_found}

      {:error, {:linear_graphql_error, _errors}} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Every page carries the time it was asked for, which the last page prunes against.
  @impl true
  def sync_issues(%Project{id: project_id}) do
    %{project_id: project_id, started_at: DateTime.utc_now()}
    |> LinearSync.new()
    |> Oban.insert()
  end

  @impl true
  def set_up_project(%Project{}), do: :ok

  @impl true
  def upload_asset(target, filename, content_type, data_binary) do
    case Linear.file_upload(target, filename, content_type, data_binary) do
      {:ok, %{"fileUpload" => %{"uploadFile" => %{"assetUrl" => asset_url}}}} -> {:ok, asset_url}
      {:ok, _not_uploaded} -> {:error, {:linear_mutation_failed, "fileUpload"}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Linear serves an uploaded file only to a token, so an `<img>` in a description cannot fetch
  # one itself; this is what the page's own URL reaches instead.
  @impl true
  def get_asset(%Issue{project: project}, path), do: Linear.get_asset(project, path)

  # Linear hears about an owner through the user's Linear id.
  @impl true
  def check_assignable(%User{linear_user_id: linear_user_id}) when is_binary(linear_user_id), do: :ok
  def check_assignable(%User{}), do: {:error, :linear_not_linked}

  defp update_linear(_project, _issue, input) when map_size(input) == 0, do: :ok

  defp update_linear(%Project{} = project, %Issue{} = issue, input) do
    case Linear.update_issue(project, issue.external_id, input) do
      {:ok, %{"issueUpdate" => %{"success" => true}}} -> :ok
      {:ok, _not_updated} -> {:error, {:linear_mutation_failed, "issueUpdate"}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp calculate_rank(%{"type" => type, "position" => position}) do
    type_rank =
      case type do
        "triage" -> 0
        "backlog" -> 1
        "unstarted" -> 2
        "started" -> 3
        _finished_or_unknown -> 4
      end

    {type_rank, position}
  end

  # An assignee with no linked Rail user leaves the issue unowned, as the full sync does.
  defp owner_user_id(linear_user_id) when is_binary(linear_user_id) do
    Repo.one(from(u in User, where: u.linear_user_id == ^linear_user_id, select: u.id))
  end

  defp owner_user_id(nil), do: nil

  # An owner who never linked Linear leaves the ticket unassigned there.
  defp linear_user_id(owner_user_id) when is_binary(owner_user_id) do
    Repo.one(from(u in User, where: u.id == ^owner_user_id, select: u.linear_user_id))
  end

  defp linear_user_id(nil), do: nil
end
