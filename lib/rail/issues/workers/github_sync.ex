defmodule Rail.Issues.Workers.GithubSync do
  @moduledoc """
  Pulls a GitHub project's issues and comments down, one page per job, the way
  `Rail.Issues.Workers.LinearSync` does for Linear. What changes afterwards arrives
  through the App's webhook.

  It takes every open issue, those closed in the last 30 days, then the repository's
  comments. When the last page lands, `{:issues_synced, project_id}` goes out on `"issues"`.

  Rows are written straight to the tables: this is GitHub telling us what it
  has, and nothing here should be pushed back.
  """
  use Oban.Worker,
    queue: :issues,
    max_attempts: 5,
    unique: [keys: [:project_id, :pass, :page], states: :incomplete]

  import Ecto.Query
  import Rail.Issues.Utils.CalculateGithubOwner
  import Rail.Issues.Utils.FormatGithubIssue

  alias Rail.GitHub.Client, as: GitHub
  alias Rail.Issues.Schemas.Comment
  alias Rail.Issues.Schemas.Issue
  alias Rail.Learnings
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Users.Schemas.User

  @closed_window_days 30

  # `branch_name` is kept as first written, so a retitled issue does not move its task's branch.
  @replace_issue [
    :project_id,
    :tracker,
    :number,
    :identifier,
    :title,
    :description,
    :priority,
    :state,
    :state_name,
    :owner_user_id,
    :url,
    :completed_at,
    :external_updated_at,
    :updated_at
  ]

  @replace_comment [:issue_id, :author_user_id, :body, :author_name, :author_avatar_url, :updated_at]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"project_id" => project_id} = args}) do
    with %Project{tracker: :github} = project <- Repo.get(Project, project_id),
         {:ok, token} <- GitHub.installation_token(project.github_installation_id) do
      args |> Map.put_new("pass", "open") |> run(project, token)
    else
      %Project{} -> :ok
      nil -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp run(%{"pass" => "comments"} = args, %Project{} = project, token) do
    page = args["page"] || 1

    with {:ok, comments} <- GitHub.list_repo_issue_comments(token, project.github_repo, page: page),
         :ok <- upsert_comments(project, comments) do
      if length(comments) == 100,
        do: continue(project, %{pass: "comments", page: page + 1}),
        else: Phoenix.PubSub.broadcast(Rail.PubSub, "issues", {:issues_synced, project.id})
    end
  end

  defp run(%{"pass" => pass} = args, %Project{} = project, token) do
    page = args["page"] || 1

    params =
      if pass == "closed",
        do: [state: "closed", page: page, since: DateTime.to_iso8601(closed_cutoff())],
        else: [state: "open", page: page]

    with {:ok, items} <- GitHub.list_issues(token, project.github_repo, params),
         {:ok, :ok} <- Repo.transaction(fn -> upsert_issues(project, keep(items, pass)) end) do
      cond do
        length(items) == 100 -> continue(project, %{pass: pass, page: page + 1})
        pass == "open" -> continue(project, %{pass: "closed", page: 1})
        true -> continue(project, %{pass: "comments", page: 1})
      end
    end
  end

  defp continue(%Project{id: project_id}, args) do
    with {:ok, _job} <- args |> Map.put(:project_id, project_id) |> new() |> Oban.insert(), do: :ok
  end

  defp closed_cutoff, do: DateTime.shift(DateTime.utc_now(), day: -@closed_window_days)

  # The issues list carries pull requests too. A closed issue counts only if it closed inside the window.
  defp keep(items, pass) do
    cutoff = closed_cutoff()

    Enum.filter(items, fn item ->
      cond do
        Map.has_key?(item, "pull_request") -> false
        pass == "closed" -> closed_since?(item["closed_at"], cutoff)
        true -> true
      end
    end)
  end

  defp closed_since?(closed_at, cutoff) when is_binary(closed_at) do
    {:ok, at, _offset} = DateTime.from_iso8601(closed_at)
    DateTime.after?(at, cutoff)
  end

  defp closed_since?(_never_closed, _cutoff), do: false

  defp upsert_issues(_project, []), do: :ok

  defp upsert_issues(%Project{id: project_id} = project, items) do
    now = DateTime.utc_now()
    existing = existing_issues(Enum.map(items, & &1["node_id"]))
    users = users_by_github_id(Enum.flat_map(items, &Enum.map(&1["assignees"] || [], fn user -> user["id"] end)))

    # insert_all won't draw a prefixed id; a row that already exists keeps its own.
    rows =
      Enum.map(items, fn item ->
        current = existing[item["node_id"]]
        known = item["assignees"] |> List.wrap() |> Enum.map(&users[to_string(&1["id"])]) |> Enum.filter(& &1)

        project
        |> format_github_issue(item)
        |> Map.merge(%{
          id: UXID.generate!(prefix: "iss"),
          project_id: project_id,
          owner_user_id: calculate_github_owner(current && current.owner_user_id, known),
          inserted_at: now,
          updated_at: now
        })
      end)

    {_count, issues} =
      Repo.insert_all(Issue, rows,
        on_conflict: {:replace, @replace_issue},
        conflict_target: :external_id,
        returning: true
      )

    # Linear tells Learnings through its webhook; a poll has to notice the finish itself.
    for %Issue{state: state, external_id: external_id} = issue <- issues,
        Issue.finished_state?(state),
        Issue.active?(existing[external_id] && existing[external_id].state) do
      {:ok, _job} = Learnings.handle_issue_finished(issue)
    end

    :ok
  end

  defp upsert_comments(%Project{id: project_id}, comments) do
    numbers = comments |> Enum.map(&issue_number/1) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    issue_ids =
      from(i in Issue,
        where: i.project_id == ^project_id and i.tracker == :github and i.number in ^numbers,
        select: {i.number, i.id}
      )
      |> Repo.all()
      |> Map.new()

    users = users_by_github_id(Enum.map(comments, &get_in(&1, ["user", "id"])))

    # Comments on pull requests, or on issues Rail never pulled, have nowhere to go.
    rows =
      for comment <- comments, issue_id = issue_ids[issue_number(comment)], issue_id != nil do
        user = comment["user"] || %{}

        %{
          id: UXID.generate!(prefix: "com"),
          issue_id: issue_id,
          external_id: comment["node_id"],
          body: comment["body"] || "",
          author_name: user["login"],
          author_avatar_url: user["avatar_url"],
          author_user_id: users[to_string(user["id"])],
          inserted_at: timestamp(comment["created_at"]),
          updated_at: timestamp(comment["updated_at"] || comment["created_at"])
        }
      end

    Repo.insert_all(Comment, rows, on_conflict: {:replace, @replace_comment}, conflict_target: :external_id)

    rows
    |> Enum.map(& &1.issue_id)
    |> Enum.uniq()
    |> Enum.each(&Phoenix.PubSub.broadcast(Rail.PubSub, "issues", {:issue_comments_changed, &1}))
  end

  defp issue_number(%{"issue_url" => url}) when is_binary(url) do
    case url |> String.split("/") |> List.last() |> Integer.parse() do
      {number, ""} -> number
      _not_a_number -> nil
    end
  end

  defp issue_number(_no_url), do: nil

  defp existing_issues(external_ids) do
    from(i in Issue,
      where: i.external_id in ^external_ids,
      select: {i.external_id, %{state: i.state, owner_user_id: i.owner_user_id}}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp users_by_github_id(github_ids) do
    ids = github_ids |> Enum.reject(&is_nil/1) |> Enum.map(&to_string/1) |> Enum.uniq()

    from(u in User, where: u.github_id in ^ids, select: {u.github_id, u.id})
    |> Repo.all()
    |> Map.new()
  end

  defp timestamp(value) do
    {:ok, %DateTime{microsecond: {usec, _precision}} = at, _offset} = DateTime.from_iso8601(value)
    %{at | microsecond: {usec, 6}}
  end
end
