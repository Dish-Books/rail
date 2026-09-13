defmodule Rail.Issues.Workers.SyncProjectIssues do
  @moduledoc """
  Pulls a project's issues down from Linear, one page per job.

  Each job fetches a page, writes it, and queues the next page behind it, so a
  team with thousands of issues is never one long request and a failure retries
  only the page it happened on. When the last page lands, `{:issues_synced,
  project_id}` goes out on the `"issues"` topic.

  Rows are written straight to the table rather than through the changeset:
  this is Linear telling us what it has, and nothing here should be pushed back.
  """
  use Oban.Worker,
    queue: :issues,
    max_attempts: 5,
    unique: [keys: [:project_id, :cursor], states: :incomplete]

  import Ecto.Query
  import Rail.Issues.Utils.FormatLinearIssue

  alias Rail.Issues.Schemas.Issue
  alias Rail.Linear.Client, as: Linear
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Users.Schemas.User

  @replace [
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

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"project_id" => project_id} = args}) do
    case Repo.get(Project, project_id) do
      %Project{} = project -> sync_page(project, args["cursor"])
      nil -> :ok
    end
  end

  defp sync_page(%Project{} = project, cursor) do
    case Linear.issues(project, after: cursor) do
      {:ok, %{"team" => %{"issues" => %{"nodes" => nodes} = issues}}} ->
        upsert(project, nodes)
        continue(project, issues["pageInfo"])

      {:ok, _no_team} ->
        {:error, :linear_team_not_found}

      {:error, reason} ->
        {:error, reason}
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

  defp upsert(%Project{id: project_id}, nodes) do
    owners = owners(nodes)
    now = DateTime.utc_now()

    # insert_all won't draw a prefixed id; a row that already exists keeps its own.
    rows =
      Enum.map(nodes, fn node ->
        node
        |> format_linear_issue()
        |> Map.merge(%{
          id: UXID.generate!(prefix: "iss"),
          project_id: project_id,
          owner_user_id: Map.get(owners, get_in(node, ["assignee", "id"])),
          inserted_at: now,
          updated_at: now
        })
      end)

    Repo.insert_all(Issue, rows, on_conflict: {:replace, @replace}, conflict_target: :external_id)

    :ok
  end

  defp owners(nodes) do
    assignee_ids = nodes |> Enum.map(&get_in(&1, ["assignee", "id"])) |> Enum.reject(&is_nil/1)

    from(u in User, where: u.linear_user_id in ^assignee_ids, select: {u.linear_user_id, u.id})
    |> Repo.all()
    |> Map.new()
  end
end
