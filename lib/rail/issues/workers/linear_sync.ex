defmodule Rail.Issues.Workers.LinearSync do
  @moduledoc """
  Pulls a project's issues and their comments down from Linear, one page per job.

  Each job fetches a page of issues with their comments, writes them together,
  and queues the next page behind it, so a team with thousands of issues is
  never one long request and a failure retries only the page it happened on.
  When the last page lands, the project's issues no page wrote since the sync
  was asked for are pruned, and `{:issues_synced, project_id}` goes out on the
  `"issues"` topic.

  An archived issue is kept only while a Rail task references it, and a trashed
  one never is: Linear has deleted it.

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
  alias Rail.Issues.Workers.AdvanceLinearState
  alias Rail.Linear.Client, as: Linear
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
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
    :completed_at,
    :linear_updated_at,
    :updated_at
  ]

  @replace_comment [:issue_id, :parent_id, :author_user_id, :body, :author_name, :author_avatar_url, :updated_at]

  @refs [:issue_external_id, :parent_external_id, :author_linear_id]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"project_id" => project_id} = args}) do
    case Repo.get(Project, project_id) do
      %Project{} = project -> sync_page(project, args["cursor"], args["started_at"])
      nil -> :ok
    end
  end

  defp sync_page(%Project{} = project, cursor, started_at) do
    with {:ok, %{"issues" => %{"nodes" => nodes} = issues}} <- Linear.issues(project, after: cursor),
         {:ok, :ok} <- Repo.transaction(fn -> upsert(project, written(nodes)) end) do
      # An empty first and only page is likelier a wrong team key than a team with nothing left.
      prune_since = if cursor == nil and nodes == [], do: nil, else: started_at
      continue(project, issues["pageInfo"], started_at, prune_since)
    end
  end

  defp continue(%Project{id: project_id}, %{"hasNextPage" => true, "endCursor" => cursor}, started_at, _prune_since) do
    with {:ok, _job} <- %{project_id: project_id, cursor: cursor, started_at: started_at} |> new() |> Oban.insert() do
      :ok
    end
  end

  defp continue(%Project{id: project_id} = project, _last_page, _started_at, prune_since) do
    with :ok <- prune(project, prune_since) do
      Phoenix.PubSub.broadcast(Rail.PubSub, "issues", {:issues_synced, project_id})
    end
  end

  defp written(nodes) do
    archived = for %{"archivedAt" => at} = node <- nodes, is_binary(at), node["trashed"] != true, do: node["id"]
    with_task = external_ids_with_task(archived)

    Enum.filter(nodes, fn node ->
      cond do
        node["trashed"] == true -> false
        is_binary(node["archivedAt"]) -> MapSet.member?(with_task, node["id"])
        true -> true
      end
    end)
  end

  defp external_ids_with_task([]), do: MapSet.new()

  defp external_ids_with_task(external_ids) do
    from(t in Task,
      join: i in Issue,
      on: i.id == t.issue_id,
      where: i.external_id in ^external_ids,
      select: i.external_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  # A job queued before syncs were stamped has no start to prune against.
  defp prune(_project, nil), do: :ok

  defp prune(%Project{id: project_id} = project, started_at) do
    {:ok, since, _offset} = DateTime.from_iso8601(started_at)

    stale =
      Repo.all(
        from(i in Issue,
          as: :issue,
          where: i.project_id == ^project_id and i.updated_at < ^since,
          select: {i.id, i.external_id, exists(from(t in Task, where: t.issue_id == parent_as(:issue).id))}
        )
      )

    {with_task, without_task} = Enum.split_with(stale, &elem(&1, 2))

    # Linear is asked outside any transaction, so what goes is re-read before any task is discarded.
    with {:ok, gone_ids} <- Enum.reduce_while(with_task, {:ok, []}, &gone_from_linear(project, &1, &2)) do
      without_task_ids = Enum.map(without_task, &elem(&1, 0))

      doomed_ids =
        Repo.all(
          from(i in Issue,
            as: :issue,
            where: i.project_id == ^project_id and i.updated_at < ^since,
            where:
              i.id in ^gone_ids or
                (i.id in ^without_task_ids and not exists(from(t in Task, where: t.issue_id == parent_as(:issue).id))),
            # A split parent's issue stays, as the webhook keeps it: its children's tasks would go with it.
            where:
              not exists(
                from(c in Task, join: p in Task, on: c.parent_task_id == p.id, where: p.issue_id == parent_as(:issue).id)
              ),
            select: i.id
          )
        )

      # Every task, cleaned up or not, is discarded first: its runs have no foreign key to go with it.
      tasks = Repo.all(from(t in Task, where: t.issue_id in ^doomed_ids))
      Enum.each(tasks, &(:ok = Pipeline.discard_task(&1)))

      Repo.delete_all(from(i in Issue, where: i.project_id == ^project_id and i.id in ^doomed_ids))

      # Sent only now, so nothing reloads while a task is still there without its issue.
      if tasks != [], do: Phoenix.PubSub.broadcast(Rail.PubSub, "sandboxes", :sandboxes_changed)
      :ok
    end
  end

  # A task's issue the pages missed may only have moved team, so only trashed or not found removes it.
  defp gone_from_linear(%Project{} = project, {id, external_id, _with_task}, {:ok, gone_ids}) do
    case Linear.issue(project, external_id) do
      {:ok, %{"issue" => %{"trashed" => true}}} ->
        {:cont, {:ok, [id | gone_ids]}}

      {:ok, %{"issue" => %{}}} ->
        {:cont, {:ok, gone_ids}}

      {:ok, %{"issue" => nil}} ->
        {:cont, {:ok, [id | gone_ids]}}

      {:error, {:linear_graphql_error, [%{"message" => "Entity not found" <> _what} | _rest]}} ->
        {:cont, {:ok, [id | gone_ids]}}

      {:error, _reason} = error ->
        {:halt, error}
    end
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

    # Read before the write, which goes round the changeset that would have queued the catch-up.
    unowned =
      Repo.all(
        from(i in Issue,
          where: i.external_id in ^Enum.map(rows, & &1.external_id) and is_nil(i.owner_user_id),
          select: i.external_id
        )
      )

    {_count, issues} =
      Repo.insert_all(Issue, rows,
        on_conflict: {:replace, @replace_issue},
        conflict_target: :external_id,
        returning: [:id, :external_id]
      )

    issue_ids = Map.new(issues, &{&1.external_id, &1.id})

    for %{external_id: external_id, owner_user_id: owner_user_id} <- rows,
        is_binary(owner_user_id) and external_id in unowned do
      %{issue_id: Map.fetch!(issue_ids, external_id)} |> AdvanceLinearState.new() |> Oban.insert!()
    end

    issue_ids
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
