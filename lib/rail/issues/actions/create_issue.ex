defmodule Rail.Issues.Actions.CreateIssue do
  @moduledoc """
  Opens a ticket in Linear and records it locally.

  Creating stays synchronous, unlike every later write. Linear is what names an
  issue — `identifier`, `branch_name`, the URL — and the pipeline uses those the
  moment the row exists: the branch a worktree is cut on and the scratch file a
  product run writes its ticket into are both named after them. An issue that had
  to wait for them would be an issue nothing could act on yet.
  """

  import Rail.Issues.Utils.FormatLinearIssue
  import Rail.Issues.Utils.LinearPriority

  alias Rail.Issues.Schemas.Issue
  alias Rail.Linear.Client, as: Linear
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Creates the Linear ticket and inserts the issue it came back as.

  `attrs` carries `:title` and `:description`, and optionally `:priority` and
  `:owner_user_id`. The ticket is opened as the scope's user, or as the
  workspace when there is no user or they never linked Linear, in triage, on
  the project's team. Broadcasts `{:issue_created, issue_id}` on `"issues"`.
  """
  def create_issue(%Scope{}, %Project{linear_team_id: nil}, %{}), do: {:error, :linear_team_not_found}

  def create_issue(%Scope{} = scope, %Project{linear_team_id: team_id} = project, %{} = attrs) do
    input =
      Map.reject(
        %{
          "teamId" => team_id,
          "title" => attrs[:title],
          "description" => attrs[:description],
          "priority" => linear_priority(attrs[:priority]),
          "stateId" => project.linear_state_ids["triage"]
        },
        fn {_key, value} -> is_nil(value) end
      )

    case Linear.create_issue(project, input, as: scope) do
      {:ok, %{"issueCreate" => %{"success" => true, "issue" => linear_issue}}} -> insert(project, linear_issue, attrs)
      {:ok, _not_created} -> {:error, {:linear_mutation_failed, "issueCreate"}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert(%Project{} = project, linear_issue, attrs) do
    local_attrs =
      linear_issue
      |> format_linear_issue()
      |> Map.merge(%{
        project_id: project.id,
        owner_user_id: attrs[:owner_user_id],
        priority: attrs[:priority] || :medium,
        state: :triage,
        state_name: get_in(linear_issue, ["state", "name"]) || "Triage"
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
end
