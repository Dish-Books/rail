defmodule Rail.Issues.Actions.CreateIssue do
  @moduledoc """
  Opens a ticket in Linear and records it locally.

  Creating stays synchronous, unlike every later write. Linear is what names an
  issue — `identifier`, `branch_name`, the URL — and the pipeline uses those the
  moment the row exists: the branch a worktree is cut on and the scratch file a
  product run writes its ticket into are both named after them. An issue that had
  to wait for them would be an issue nothing could act on yet.
  """

  import Ecto.Query
  import Rail.Issues.Utils.FormatLinearIssue
  import Rail.Issues.Utils.LinearPriority

  alias Rail.Issues.Schemas.Issue
  alias Rail.Linear.Client, as: Linear
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users.Schemas.User

  @doc """
  Creates the Linear ticket and inserts the issue it came back as.

  `attrs` carries `:title` and `:description`, and optionally `:priority`, `:estimate`,
  `:owner_user_id`, assigned in Linear too, and `:parent`, the issue it is a sub-issue of. The ticket
  is opened as the scope's user, or as the workspace when there is no user or they never linked
  Linear, on the project's team: in triage, or in Todo for a sub-issue, whose work is already planned.
  Broadcasts `{:issue_created, issue_id}` on `"issues"`.
  """
  def create_issue(%Scope{}, %Project{linear_team_id: nil}, %{}), do: {:error, :linear_team_not_found}

  def create_issue(%Scope{} = scope, %Project{linear_team_id: team_id} = project, %{} = attrs) do
    state = if attrs[:parent], do: :todo, else: :triage

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
        insert(project, linear_issue, attrs, state)

      {:ok, _not_created} ->
        {:error, {:linear_mutation_failed, "issueCreate"}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp insert(%Project{} = project, linear_issue, attrs, state) do
    local_attrs =
      linear_issue
      |> format_linear_issue()
      |> Map.merge(%{
        project_id: project.id,
        owner_user_id: attrs[:owner_user_id],
        priority: attrs[:priority] || :medium,
        estimate: attrs[:estimate],
        state: state,
        state_name: get_in(linear_issue, ["state", "name"]) || Issue.state_label(state)
      })

    # The project is what the caller already handed us: carry it on the issue so
    # nothing downstream has to fetch it again.
    case %Issue{} |> Issue.changeset(local_attrs) |> Repo.insert() do
      {:ok, %Issue{} = issue} ->
        Phoenix.PubSub.broadcast(Rail.PubSub, "issues", {:issue_created, issue.id})
        {:ok, %{issue | project: project}}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  # An owner who never linked Linear leaves the ticket unassigned there.
  defp linear_user_id(owner_user_id) when is_binary(owner_user_id) do
    Repo.one(from(u in User, where: u.id == ^owner_user_id, select: u.linear_user_id))
  end

  defp linear_user_id(nil), do: nil
end
