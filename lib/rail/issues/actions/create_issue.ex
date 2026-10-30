defmodule Rail.Issues.Actions.CreateIssue do
  @moduledoc """
  Opens a ticket in the project's tracker and records it locally.

  Creating stays synchronous, unlike every later write. The tracker is what names an
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

  `attrs` carries `:title` and `:description`, and optionally `:priority`, `:estimate`,
  `:owner_user_id`, `:workflow_id`, the workflow opening it, `:skipped_steps`, the steps its file
  turned off, `:stages`, the `IssueStage`s its file named, and `:parent`, the issue it is a sub-issue of. The ticket is opened in triage, or in Todo for a sub-issue, whose work is
  already planned. Broadcasts `{:issue_created, issue_id}` on `"issues"`.
  """
  def create_issue(%Scope{} = scope, %Project{} = project, %{} = attrs) do
    state = if attrs[:parent], do: :todo, else: :triage

    with {:ok, tracked} <- Tracker.tracker(project).create_issue(scope, project, Map.put(attrs, :state, state)) do
      local =
        Map.merge(tracked, %{
          tracker: project.tracker,
          project_id: project.id,
          owner_user_id: attrs[:owner_user_id],
          priority: attrs[:priority] || :medium,
          estimate: attrs[:estimate],
          workflow_id: attrs[:workflow_id]
        })

      # A tracker's webhook can announce the ticket before this insert, so the row it saved is kept.
      # Set on the struct rather than cast, so no tracker write can change the steps after; `Issue.changeset/2`
      # takes no cycle or parent, which GitHub never sends.
      %Issue{
        skipped_steps: attrs[:skipped_steps] || [],
        stages: attrs[:stages] || [],
        cycle_external_id: tracked[:cycle_external_id],
        parent_external_id: tracked[:parent_external_id]
      }
      |> Issue.changeset(local)
      |> Repo.insert(
        on_conflict: {:replace_all_except, [:id, :branch_name, :inserted_at, :cycle_external_id, :parent_external_id]},
        conflict_target: :external_id,
        returning: true
      )
      |> case do
        # The project is what the caller already handed us: carry it on the issue so
        # nothing downstream has to fetch it again.
        {:ok, %Issue{} = issue} ->
          Phoenix.PubSub.broadcast(Rail.PubSub, "issues", {:issue_created, issue.id})
          {:ok, %{issue | project: project}}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end
end
