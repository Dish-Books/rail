defmodule Rail.Issues.Actions.CreateIssue do
  @moduledoc """
  Opens a ticket.

  Postgres names an
  issue (`identifier`, `branch_name`, the URL), and the pipeline uses those the
  moment the row exists: the branch a worktree is cut on and the scratch file a
  product run writes its ticket into are both named after them. An issue that had
  to wait for them would be an issue nothing could act on yet.
  """

  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Tracker
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Creates the ticket and inserts the issue it came back as.

  A blank title or an estimate below 0 is the changeset's error.

  `attrs` carries `:title` and `:description`, and optionally `:priority`, `:estimate`,
  `:owner_user_id`, `:workflow_id`, the workflow opening it, `:skipped_steps`, the steps its file
  turned off, `:stages`, the `IssueStage`s its file named, `:parent`, the issue it is a sub-issue of, and `:cycle_id`,
  the cycle the ticket opens in, which the caller has already checked. The ticket is opened in triage, or in
  Todo for a sub-issue, whose work is already planned. Broadcasts `{:issue_created, issue_id}` on `"issues"`.
  """
  def create_issue(%Scope{} = scope, %Project{} = project, %{} = attrs) do
    state = if attrs[:parent], do: :todo, else: :triage

    case Issue.edit_changeset(%Issue{}, Map.take(attrs, [:title, :estimate])) do
      %Ecto.Changeset{valid?: true} ->
        {:ok, tracked} = Tracker.create_issue(scope, project, Map.put(attrs, :state, state))

        local =
          Map.merge(tracked, %{
            project_id: project.id,
            owner_user_id: attrs[:owner_user_id],
            priority: attrs[:priority] || :medium,
            estimate: attrs[:estimate],
            workflow_id: attrs[:workflow_id]
          })

        # Set on the struct rather than cast, so no later write can change the steps; `Issue.changeset/2` takes no cycle
        # or parent.
        %Issue{
          skipped_steps: attrs[:skipped_steps] || [],
          stages: attrs[:stages] || [],
          cycle_id: tracked[:cycle_id],
          parent_id: tracked[:parent_id]
        }
        |> Issue.changeset(local)
        # The tracker draws the id its URL names. On the struct it would make the insert read as an update.
        |> Ecto.Changeset.put_change(:id, tracked[:id])
        |> Repo.insert(returning: true)
        |> case do
          # The project is what the caller already handed us: carry it on the issue so
          # nothing downstream has to fetch it again.
          {:ok, %Issue{} = issue} ->
            Phoenix.PubSub.broadcast(Rail.PubSub, "issues", {:issue_created, issue.id})
            {:ok, %{issue | project: project}}

          {:error, changeset} ->
            {:error, changeset}
        end

      %Ecto.Changeset{} = changeset ->
        {:error, changeset}
    end
  end
end
