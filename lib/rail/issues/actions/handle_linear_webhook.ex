defmodule Rail.Issues.Actions.HandleLinearWebhook do
  @moduledoc """
  Mirrors an issue event Linear sent for a workspace into Rail.

  The row is written with `Issue.linear_changeset/2`: the change came from
  Linear, so nothing is pushed back to it. An update that finishes an open issue
  is handed to Learnings and the pipeline, which only queue their work.
  """

  import Ecto.Query
  import Rail.Issues.Utils.FormatLinearIssue
  import Rail.Issues.Utils.UpsertLinearComment

  alias Rail.Issues.Schemas.Comment
  alias Rail.Issues.Schemas.Issue
  alias Rail.Learnings
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.LinearWorkspace
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Users.Schemas.User

  require Logger

  @doc """
  Applies `payload` for `workspace`, its projects preloaded. Issue creates and
  updates are upserted onto the project on the issue's team and broadcast as
  `{:issue_changed, issue_id}` on `"issues"`, removes delete the issue, and
  anything else, including a team no project is on, is ignored.
  """
  def handle_linear_webhook(%LinearWorkspace{projects: projects}, %{
        "type" => "Issue",
        "action" => action,
        "data" => %{"id" => external_id, "teamId" => team_id} = data
      })
      when action in ["create", "update"] do
    case Enum.find(projects, &(&1.linear_team_id == team_id)) do
      %Project{id: project_id} ->
        attrs =
          data
          |> format_linear_issue()
          |> Map.merge(%{project_id: project_id, owner_user_id: owner_user_id(data["assigneeId"])})

        existing = Repo.get_by(Issue, external_id: external_id) || %Issue{}

        with {:ok, issue} <- existing |> Issue.linear_changeset(attrs) |> Repo.insert_or_update() do
          # A child's owner is its parent's, so a new owner on a split parent reaches its children.
          if is_binary(existing.id) and existing.owner_user_id != issue.owner_user_id,
            do: {:ok, _children} = Pipeline.share_owner_with_children(issue)

          if finished?(action, existing, issue) do
            {:ok, _job} = Learnings.handle_issue_finished(issue)
            Pipeline.handle_issue_finished(issue)
          end

          Phoenix.PubSub.broadcast(Rail.PubSub, "issues", {:issue_changed, issue.id})
          {:ok, issue}
        end

      nil ->
        :ok
    end
  end

  def handle_linear_webhook(%LinearWorkspace{}, %{
        "type" => "Issue",
        "action" => "remove",
        "data" => %{"id" => external_id}
      }) do
    case Repo.get_by(Issue, external_id: external_id) do
      %Issue{} = issue -> delete_issue(issue)
      nil -> :ok
    end
  end

  def handle_linear_webhook(%LinearWorkspace{}, %{
        "type" => "Comment",
        "action" => action,
        "data" => %{"id" => _external_id} = data
      })
      when action in ["create", "update"] do
    case upsert_linear_comment(data) do
      # Its issue or thread has not been synced yet; the next sync brings it in.
      {:error, reason} when reason in [:issue_not_found, :parent_not_found] -> :ok
      result -> result
    end
  end

  def handle_linear_webhook(%LinearWorkspace{}, %{
        "type" => "Comment",
        "action" => "remove",
        "data" => %{"id" => external_id}
      }) do
    case Repo.get_by(Comment, external_id: external_id) do
      %Comment{} = comment ->
        with {:ok, comment} <- Repo.delete(comment) do
          Phoenix.PubSub.broadcast(Rail.PubSub, "issues", {:issue_comments_changed, comment.issue_id})
          {:ok, comment}
        end

      nil ->
        :ok
    end
  end

  def handle_linear_webhook(%LinearWorkspace{}, _payload), do: :ok

  # A split parent's issue keeps its row: deleting it would take the children's tasks, mid-work, with it.
  defp delete_issue(%Issue{id: issue_id} = issue) do
    split? =
      Repo.exists?(from(c in Task, join: p in Task, on: c.parent_task_id == p.id, where: p.issue_id == ^issue_id))

    if split? do
      Logger.warning("Linear removed #{issue.identifier}, which Rail split into child tasks, so Rail keeps it")
      :ok
    else
      Repo.delete(issue)
    end
  end

  defp finished?("update", %Issue{id: id, state: was}, %Issue{state: now}) when is_binary(id),
    do: not Issue.finished_state?(was) and Issue.finished_state?(now)

  defp finished?(_action, _existing, _issue), do: false

  # An assignee with no linked Rail user leaves the issue unowned, as the full sync does.
  defp owner_user_id(linear_user_id) when is_binary(linear_user_id) do
    Repo.one(from(u in User, where: u.linear_user_id == ^linear_user_id, select: u.id))
  end

  defp owner_user_id(nil), do: nil
end
