defmodule Rail.Issues.Actions.HandleLinearWebhook do
  @moduledoc """
  Mirrors an issue event Linear sent for a workspace into Rail.

  The row is written with `Issue.tracker_changeset/2`: the change came from
  Linear, so nothing is pushed back to it. An update that finishes an open issue
  is handed to Learnings and the pipeline, which only queue their work.

  Every issue event carries the whole ticket, and two sent close together can
  arrive in either order. So the row is locked while it is written, and an event
  older than what the row already holds, by Linear's `updatedAt`, is dropped.
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
  `{:issue_changed, issue_id}` on `"issues"`. A remove or a trash deletes the
  issue and its task, and so does an archive when no task references it, both
  broadcast the same way. Anything else, including a team no project is on or an
  update older than the row, is ignored.
  """
  def handle_linear_webhook(%LinearWorkspace{projects: projects}, %{
        "type" => "Issue",
        "action" => action,
        "data" => %{"id" => external_id, "trashed" => true}
      })
      when action in ["create", "update"] do
    delete_issue(projects, external_id)
  end

  def handle_linear_webhook(%LinearWorkspace{projects: projects}, %{
        "type" => "Issue",
        "action" => action,
        "data" => %{"id" => external_id, "archivedAt" => archived_at} = data
      })
      when action in ["create", "update"] and is_binary(archived_at) do
    if Repo.exists?(from(t in Task, join: i in assoc(t, :issue), where: i.external_id == ^external_id)),
      do: upsert_issue(projects, action, data),
      else: delete_issue_without_task(projects, external_id)
  end

  def handle_linear_webhook(%LinearWorkspace{projects: projects}, %{
        "type" => "Issue",
        "action" => action,
        "data" => %{"id" => _external_id, "teamId" => _team_id} = data
      })
      when action in ["create", "update"] do
    upsert_issue(projects, action, data)
  end

  def handle_linear_webhook(%LinearWorkspace{projects: projects}, %{
        "type" => "Issue",
        "action" => "remove",
        "data" => %{"id" => external_id}
      }) do
    delete_issue(projects, external_id)
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

  defp upsert_issue(projects, action, %{"id" => external_id} = data) do
    case Enum.find(projects, &(&1.linear_team_id == data["teamId"])) do
      %Project{id: project_id} ->
        attrs =
          data
          |> format_linear_issue()
          |> Map.merge(%{project_id: project_id, owner_user_id: owner_user_id(data["assigneeId"])})

        {:ok, {existing, result}} =
          Repo.transaction(fn ->
            existing =
              Repo.one(from(i in Issue, where: i.external_id == ^external_id, lock: "FOR UPDATE")) || %Issue{}

            if stale?(existing, attrs),
              do: {existing, :ok},
              else: {existing, existing |> Issue.tracker_changeset(attrs) |> Repo.insert_or_update()}
          end)

        with {:ok, issue} <- result do
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

  # Every task, cleaned up or not, is discarded first: its runs have no foreign key to go with it.
  # A split parent's issue keeps its row, since deleting it would take the children's tasks with it.
  defp delete_issue(projects, external_id) do
    project_ids = Enum.map(projects, & &1.id)

    split? =
      Repo.exists?(
        from(c in Task,
          join: p in Task,
          on: c.parent_task_id == p.id,
          join: i in assoc(p, :issue),
          where: i.external_id == ^external_id and i.project_id in ^project_ids
        )
      )

    if split? do
      Logger.warning("Linear removed #{external_id}, which Rail split into child tasks, so Rail keeps it")
      :ok
    else
      discard_and_delete(project_ids, external_id)
    end
  end

  defp discard_and_delete(project_ids, external_id) do
    tasks =
      Repo.all(
        from(t in Task,
          join: i in assoc(t, :issue),
          where: i.external_id == ^external_id and i.project_id in ^project_ids
        )
      )

    Enum.each(tasks, &(:ok = Pipeline.discard_task(&1)))

    result =
      delete_and_broadcast(
        from(i in Issue, where: i.external_id == ^external_id and i.project_id in ^project_ids, select: i)
      )

    # Sent only now, so nothing reloads while a task is still there without its issue.
    if tasks != [], do: Phoenix.PubSub.broadcast(Rail.PubSub, "sandboxes", :sandboxes_changed)
    result
  end

  defp delete_issue_without_task(projects, external_id) do
    project_ids = Enum.map(projects, & &1.id)

    delete_and_broadcast(
      from(i in Issue,
        as: :issue,
        where: i.external_id == ^external_id and i.project_id in ^project_ids,
        where: not exists(from(t in Task, where: t.issue_id == parent_as(:issue).id)),
        select: i
      )
    )
  end

  # One statement, so a second remove or a task started meanwhile finds nothing to delete.
  defp delete_and_broadcast(query) do
    case Repo.delete_all(query) do
      {1, [issue]} ->
        Phoenix.PubSub.broadcast(Rail.PubSub, "issues", {:issue_changed, issue.id})
        {:ok, issue}

      {0, []} ->
        :ok
    end
  end

  defp finished?("update", %Issue{id: id, state: was}, %Issue{state: now}) when is_binary(id),
    do: not Issue.finished_state?(was) and Issue.finished_state?(now)

  defp finished?(_action, _existing, _issue), do: false

  defp stale?(%Issue{external_updated_at: %DateTime{} = have}, %{external_updated_at: %DateTime{} = sent}),
    do: DateTime.before?(sent, have)

  defp stale?(_existing, _attrs), do: false

  # An assignee with no linked Rail user leaves the issue unowned, as the full sync does.
  defp owner_user_id(linear_user_id) when is_binary(linear_user_id) do
    Repo.one(from(u in User, where: u.linear_user_id == ^linear_user_id, select: u.id))
  end

  defp owner_user_id(nil), do: nil
end
