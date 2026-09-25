defmodule Rail.Issues.Actions.HandleLinearWebhook do
  @moduledoc """
  Mirrors an issue event Linear sent for a workspace into Rail.

  The row is written with `Issue.linear_changeset/2`: the change came from
  Linear, so nothing is pushed back to it.
  """

  import Ecto.Query
  import Rail.Issues.Utils.FormatLinearIssue
  import Rail.Issues.Utils.UpsertLinearComment

  alias Rail.Issues.Schemas.Comment
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects.Schemas.LinearWorkspace
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Users.Schemas.User

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

        with {:ok, issue} <-
               (Repo.get_by(Issue, external_id: external_id) || %Issue{})
               |> Issue.linear_changeset(attrs)
               |> Repo.insert_or_update() do
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
      %Issue{} = issue -> Repo.delete(issue)
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

  # An assignee with no linked Rail user leaves the issue unowned, as the full sync does.
  defp owner_user_id(linear_user_id) when is_binary(linear_user_id) do
    Repo.one(from(u in User, where: u.linear_user_id == ^linear_user_id, select: u.id))
  end

  defp owner_user_id(nil), do: nil
end
