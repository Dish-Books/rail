defmodule Rail.Issues.Actions.HandleGithubWebhook do
  @moduledoc """
  Mirrors an `issues` or `issue_comment` event the GitHub App sent for a project's repository
  into Rail, as `Rail.Issues.Actions.HandleLinearWebhook` does for Linear.

  The row is written with `Issue.tracker_changeset/2`: the change came from GitHub, so nothing
  is pushed back to it. An update that finishes an open issue is handed to Learnings.
  """

  import Ecto.Query
  import Rail.Issues.Utils.CalculateGithubOwner
  import Rail.Issues.Utils.FormatGithubIssue
  import Rail.Issues.Utils.UpsertGithubComment

  alias Rail.Issues.Schemas.Comment
  alias Rail.Issues.Schemas.Issue
  alias Rail.Learnings
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Users.Schemas.User

  @doc """
  Applies `payload` of GitHub `event` to `project`. An issue opened or changed is upserted and
  broadcast as `{:issue_changed, issue_id}` on `"issues"`, one deleted or moved to another
  repository is deleted, comments follow the same way, and anything else is ignored. Deliveries
  arrive in any order, so one older than what Rail holds changes nothing.
  """
  def handle_github_webhook(%Project{} = project, "issues", %{"action" => action, "issue" => %{"node_id" => external_id}})
      when action in ["deleted", "transferred"] do
    case Repo.get_by(Issue, project_id: project.id, external_id: external_id) do
      %Issue{} = issue -> Repo.delete(issue)
      nil -> :ok
    end
  end

  def handle_github_webhook(%Project{} = project, "issues", %{"issue" => %{"node_id" => external_id} = payload_issue}) do
    attrs = format_github_issue(project, payload_issue)
    existing = Repo.get_by(Issue, external_id: external_id) || %Issue{}

    if stale?(existing, attrs) do
      :ok
    else
      owner = calculate_github_owner(existing.owner_user_id, assignee_user_ids(payload_issue["assignees"]))
      attrs = Map.merge(attrs, %{project_id: project.id, owner_user_id: owner})

      with {:ok, issue} <- existing |> Issue.tracker_changeset(attrs) |> Repo.insert_or_update() do
        if finished?(existing, issue), do: {:ok, _job} = Learnings.handle_issue_finished(issue)
        Phoenix.PubSub.broadcast(Rail.PubSub, "issues", {:issue_changed, issue.id})
        {:ok, issue}
      end
    end
  end

  # A comment on a pull request comes as an `issue_comment` too, and has no issue in Rail.
  def handle_github_webhook(%Project{}, "issue_comment", %{"issue" => %{"pull_request" => _pull_request}}), do: :ok

  def handle_github_webhook(%Project{}, "issue_comment", %{
        "action" => "deleted",
        "comment" => %{"node_id" => external_id}
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

  # An issue Rail has not pulled yet gets its comments with the next sync.
  def handle_github_webhook(%Project{} = project, "issue_comment", %{
        "issue" => %{"number" => number},
        "comment" => comment
      }) do
    case Repo.get_by(Issue, project_id: project.id, tracker: :github, number: number) do
      %Issue{} = issue -> upsert_github_comment(issue, comment)
      nil -> :ok
    end
  end

  def handle_github_webhook(%Project{}, _event, _payload), do: :ok

  defp stale?(%Issue{external_updated_at: %DateTime{} = held}, %{external_updated_at: %DateTime{} = sent}),
    do: DateTime.before?(sent, held)

  defp stale?(%Issue{}, _attrs), do: false

  defp finished?(%Issue{id: id, state: was}, %Issue{state: now}) when is_binary(id),
    do: not Issue.finished_state?(was) and Issue.finished_state?(now)

  defp finished?(%Issue{}, %Issue{}), do: false

  defp assignee_user_ids(assignees) do
    github_ids = assignees |> List.wrap() |> Enum.map(&to_string(&1["id"]))
    known = Map.new(Repo.all(from u in User, where: u.github_id in ^github_ids, select: {u.github_id, u.id}))
    github_ids |> Enum.map(&known[&1]) |> Enum.filter(& &1)
  end
end
