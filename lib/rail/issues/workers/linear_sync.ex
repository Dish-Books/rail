defmodule Rail.Issues.Workers.LinearSync do
  @moduledoc """
  Pulls a project's issues and their comments down from Linear, one page per job.

  Each job fetches a page of issues with their comments, writes them together,
  and queues the next page behind it, so a team with thousands of issues is
  never one long request and a failure retries only the page it happened on.
  When the last page lands, `{:issues_synced, project_id}` goes out on the
  `"issues"` topic.

  Rows are written straight to the tables rather than through the changesets:
  this is Linear telling us what it has, and nothing here should be pushed back.
  """
  use Oban.Worker,
    queue: :issues,
    max_attempts: 5,
    unique: [keys: [:project_id, :cursor], states: :incomplete]

  import Ecto.Query
  import Rail.Issues.Utils.FormatLinearComment
  import Rail.Issues.Utils.FormatLinearIssue

  alias Rail.Issues.Schemas.Comment
  alias Rail.Issues.Schemas.Issue
  alias Rail.Linear.Client, as: Linear
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Users.Schemas.User

  @replace_issue [
    :project_id,
    :identifier,
    :title,
    :description,
    :priority,
    :estimate,
    :state,
    :state_name,
    :owner_user_id,
    :branch_name,
    :url,
    :updated_at
  ]

  @replace_comment [:issue_id, :parent_id, :author_user_id, :body, :author_name, :author_avatar_url, :updated_at]

  @refs [:issue_external_id, :parent_external_id, :author_linear_id]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"project_id" => project_id} = args}) do
    case Repo.get(Project, project_id) do
      %Project{} = project -> sync_page(project, args["cursor"])
      nil -> :ok
    end
  end

  defp sync_page(%Project{} = project, cursor) do
    with {:ok, %{"issues" => %{"nodes" => nodes} = issues}} <- Linear.issues(project, after: cursor),
         {:ok, :ok} <- Repo.transaction(fn -> upsert(project, nodes) end) do
      continue(project, issues["pageInfo"])
    end
  end

  defp continue(%Project{id: project_id}, %{"hasNextPage" => true, "endCursor" => cursor}) do
    with {:ok, _job} <- %{project_id: project_id, cursor: cursor} |> new() |> Oban.insert() do
      :ok
    end
  end

  defp continue(%Project{id: project_id}, _last_page) do
    Phoenix.PubSub.broadcast(Rail.PubSub, "issues", {:issues_synced, project_id})
  end

  defp upsert(_project, []), do: :ok

  defp upsert(%Project{} = project, nodes) do
    comments =
      for node <- nodes, comment <- get_in(node, ["comments", "nodes"]) || [] do
        {refs, attrs} = comment |> format_linear_comment() |> Map.split(@refs)
        {%{refs | issue_external_id: node["id"]}, attrs}
      end

    linear_user_ids =
      Enum.map(nodes, &get_in(&1, ["assignee", "id"])) ++ Enum.map(comments, &elem(&1, 0).author_linear_id)

    users = users_by_linear_id(linear_user_ids)
    issue_ids = upsert_issues(project, nodes, users)

    # A reply needs its parent's Rail id, so the threads' first comments go in first.
    {replies, top_level} = Enum.split_with(comments, fn {refs, _attrs} -> refs.parent_external_id end)
    upsert_comments(top_level, issue_ids, users, %{})

    parent_ids = comment_ids(Enum.map(replies, &elem(&1, 0).parent_external_id))
    upsert_comments(replies, issue_ids, users, parent_ids)
  end

  defp upsert_issues(%Project{id: project_id}, nodes, users) do
    now = DateTime.utc_now()

    # insert_all won't draw a prefixed id; a row that already exists keeps its own.
    rows =
      Enum.map(nodes, fn node ->
        node
        |> format_linear_issue()
        |> Map.merge(%{
          id: UXID.generate!(prefix: "iss"),
          project_id: project_id,
          owner_user_id: Map.get(users, get_in(node, ["assignee", "id"])),
          inserted_at: now,
          updated_at: now
        })
      end)

    {_count, issues} =
      Repo.insert_all(Issue, rows,
        on_conflict: {:replace, @replace_issue},
        conflict_target: :external_id,
        returning: [:id, :external_id]
      )

    Map.new(issues, &{&1.external_id, &1.id})
  end

  defp upsert_comments(comments, issue_ids, users, parent_ids) do
    rows =
      for {refs, attrs} <- comments,
          refs.parent_external_id == nil or Map.has_key?(parent_ids, refs.parent_external_id) do
        Map.merge(attrs, %{
          id: UXID.generate!(prefix: "com"),
          issue_id: Map.fetch!(issue_ids, refs.issue_external_id),
          parent_id: Map.get(parent_ids, refs.parent_external_id),
          author_user_id: Map.get(users, refs.author_linear_id)
        })
      end

    Repo.insert_all(Comment, rows, on_conflict: {:replace, @replace_comment}, conflict_target: :external_id)

    :ok
  end

  defp comment_ids([]), do: %{}

  defp comment_ids(external_ids) do
    from(c in Comment, where: c.external_id in ^external_ids, select: {c.external_id, c.id})
    |> Repo.all()
    |> Map.new()
  end

  defp users_by_linear_id(linear_user_ids) do
    ids = linear_user_ids |> Enum.reject(&is_nil/1) |> Enum.uniq()

    from(u in User, where: u.linear_user_id in ^ids, select: {u.linear_user_id, u.id})
    |> Repo.all()
    |> Map.new()
  end
end
