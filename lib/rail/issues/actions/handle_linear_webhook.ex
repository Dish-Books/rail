defmodule Rail.Issues.Actions.HandleLinearWebhook do
  @moduledoc """
  Mirrors an issue event Linear sent for a workspace into Rail.

  The row is written with `Issue.linear_changeset/2`: the change came from
  Linear, so nothing is pushed back to it. An update that finishes an open issue
  is handed to Learnings, which only queues its work.
  """

  import Ecto.Query
  import Rail.Issues.Utils.FormatLinearIssue
  import Rail.Issues.Utils.UpsertLinearComment

  alias Rail.Issues.Schemas.Comment
  alias Rail.Issues.Schemas.Issue
  alias Rail.Learnings
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.LinearWorkspace
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Users.Schemas.User

  @doc """
  Applies `payload` for `workspace`, its projects preloaded. Issue creates and
  updates are upserted onto the project on the issue's team and broadcast as
  `{:issue_changed, issue_id}` on `"issues"`. A remove or a trash deletes the
  issue and its task, and so does an archive when no task references it, both
  broadcast the same way. Anything else, including a team no project is on, is ignored.
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
      else: delete_issue(projects, external_id, without_task: true)
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

        existing = Repo.get_by(Issue, external_id: external_id) || %Issue{}

        with {:ok, issue} <- existing |> Issue.linear_changeset(attrs) |> Repo.insert_or_update() do
          if finished?(action, existing, issue), do: {:ok, _job} = Learnings.handle_issue_finished(issue)
          Phoenix.PubSub.broadcast(Rail.PubSub, "issues", {:issue_changed, issue.id})
          {:ok, issue}
        end

      nil ->
        :ok
    end
  end

  # One statement, so a second remove or a task started meanwhile finds nothing to delete.
  defp delete_issue(projects, external_id, opts \\ []) do
    project_ids = Enum.map(projects, & &1.id)

    query =
      from(i in Issue,
        as: :issue,
        where: i.external_id == ^external_id and i.project_id in ^project_ids,
        select: i
      )

    query =
      if opts[:without_task],
        do: where(query, not exists(from(t in Task, where: t.issue_id == parent_as(:issue).id))),
        else: query

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

  # An assignee with no linked Rail user leaves the issue unowned, as the full sync does.
  defp owner_user_id(linear_user_id) when is_binary(linear_user_id) do
    Repo.one(from(u in User, where: u.linear_user_id == ^linear_user_id, select: u.id))
  end

  defp owner_user_id(nil), do: nil
end
