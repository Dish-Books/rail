defmodule Rail.Issues.Tracker.Github do
  @moduledoc """
  Issues kept in GitHub Issues, written as the project's GitHub App. State and priority live in
  `rail:` labels, and a ticket is named `<key>#<number>`. GitHub reports its changes through the
  App's webhook.

  Labels and assignees are added and removed one at a time, never replaced, so the ones people
  set on GitHub themselves survive.
  """
  @behaviour Rail.Issues.Tracker

  import Rail.Issues.Utils.CalculateGithubState
  import Rail.Issues.Utils.FormatGithubIssue
  import Rail.Issues.Utils.GithubIssueLabels
  import Rail.Issues.Utils.UpsertGithubComment

  alias Rail.GitHub.Client, as: GitHub
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Workers.EnsureGithubLabels
  alias Rail.Issues.Workers.GithubSync
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Users.Schemas.User

  @ranks %{triage: 0, backlog: 1, todo: 2, in_progress: 3, in_review: 4, done: 5}

  @impl true
  # GitHub has no estimate; a sub-issue goes up as an issue of its own.
  def create_issue(_scope, %Project{} = project, %{state: state} = attrs) do
    priority = attrs[:priority] || :medium
    owner = attrs[:owner_user_id] && Repo.get(User, attrs[:owner_user_id])

    labels =
      for %{name: name} = label <- github_issue_labels(), label.state == state or label.priority == priority, do: name

    input =
      Map.reject(
        %{
          "title" => attrs[:title],
          "body" => attrs[:description],
          "labels" => labels,
          "assignees" => if(owner, do: [owner.login])
        },
        fn {_key, value} -> is_nil(value) end
      )

    with {:ok, token} <- token(project),
         {:ok, github_issue} <- GitHub.create_issue(token, project.github_repo, input) do
      {:ok, format_github_issue(project, github_issue)}
    end
  end

  @impl true
  def update_issue(%Issue{project: %Project{} = project} = issue, fields, previous_owner) do
    with {:ok, token} <- token(project),
         {:ok, live} <- live_issue(token, project, issue, fields),
         :ok <- patch(token, project, issue, live, fields),
         :ok <-
           relabel(token, project, issue, live, :state in fields and issue.state not in Issue.finished_states(), :state),
         :ok <- relabel(token, project, issue, live, :priority in fields, :priority) do
      reassign(token, project, issue, :owner_user_id in fields, previous_owner)
    end
  end

  # A closed issue ranks past every open state, so it is never reopened from here.
  @impl true
  def advance_issue(%Issue{project: %Project{} = project} = issue, target) do
    with {:ok, token} <- token(project),
         {:ok, live} <- GitHub.get_issue(token, project.github_repo, issue.number) do
      cond do
        Map.get(@ranks, calculate_github_state(live), 5) >= @ranks[target] -> :ok
        target == :done -> close_issue(token, project, issue)
        true -> swap_label(token, project, issue, live, :state, target)
      end
    end
  end

  # A merge into the default branch closes the issue through the pull request's `Closes #N`; this
  # closes one the merge did not, such as a split parent's.
  defp close_issue(token, %Project{github_repo: repo}, %Issue{number: number}) do
    with {:ok, _closed} <- GitHub.update_issue(token, repo, number, %{state: "closed", state_reason: "completed"}),
         do: :ok
  end

  # GitHub comments are flat, so a reply goes up as a new comment quoting the one it answers.
  @impl true
  def create_comment(_scope, %Issue{} = issue, body, parent) do
    project = Repo.get(Project, issue.project_id)
    quoted = if parent, do: quote_lines(parent.body) <> "\n\n", else: ""

    with {:ok, token} <- token(project),
         {:ok, comment} <- GitHub.create_issue_comment(token, project.github_repo, issue.number, quoted <> body) do
      upsert_github_comment(issue, comment)
    end
  end

  # An issue is named by its number: `key#123`, `#123` or `123`.
  @impl true
  def canonical_identifier(%Project{key: key}, identifier) do
    case identifier |> String.split("#") |> List.last() |> Integer.parse() do
      {number, ""} -> {:ok, "#{key}##{number}"}
      _not_a_number -> :error
    end
  end

  # A pull request shares the issues' numbering, but it is not one.
  @impl true
  def fetch_issue(%Project{} = project, identifier) do
    {:ok, canonical} = canonical_identifier(project, identifier)
    [_key, number] = String.split(canonical, "#")

    with {:ok, token} <- token(project),
         {:ok, github_issue} when not is_map_key(github_issue, "pull_request") <-
           GitHub.get_issue(token, project.github_repo, number) do
      {:ok, format_github_issue(project, github_issue)}
    else
      {:ok, _pull_request} -> {:error, :not_found}
      {:error, {:github_api_error, 404, _body}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def sync_issues(%Project{id: project_id}), do: %{project_id: project_id} |> GithubSync.new() |> Oban.insert()

  # The labels are made before an issue first needs one, with their colors and descriptions.
  @impl true
  def set_up_project(%Project{id: project_id}) do
    with {:ok, _job} <- %{project_id: project_id} |> EnsureGithubLabels.new() |> Oban.insert(), do: :ok
  end

  # GitHub has no API to attach a file to an issue.
  @impl true
  def upload_asset(_target, _filename, _content_type, _data_binary), do: {:error, :unsupported}

  @impl true
  def get_asset(%Issue{}, _path), do: {:error, :unsupported}

  # Everyone signs in with GitHub, so anyone can own a GitHub issue.
  @impl true
  def check_assignable(%User{}), do: :ok

  defp token(%Project{github_installation_id: installation_id}), do: GitHub.installation_token(installation_id)

  # Labels and whether it is open are only known from GitHub, and only matter when they change.
  defp live_issue(token, %Project{} = project, %Issue{} = issue, fields) do
    if :state in fields or :priority in fields,
      do: GitHub.get_issue(token, project.github_repo, issue.number),
      else: {:ok, nil}
  end

  defp patch(token, %Project{} = project, %Issue{} = issue, live, fields) do
    attrs =
      Enum.reduce(fields, %{}, fn
        :title, attrs -> Map.put(attrs, "title", issue.title)
        :description, attrs -> Map.put(attrs, "body", issue.description || "")
        :state, attrs -> Map.merge(attrs, github_state(issue.state, live))
        _labelled_or_unmapped, attrs -> attrs
      end)

    if map_size(attrs) == 0 do
      :ok
    else
      with {:ok, _updated} <- GitHub.update_issue(token, project.github_repo, issue.number, attrs), do: :ok
    end
  end

  defp github_state(:done, _live), do: %{"state" => "closed", "state_reason" => "completed"}
  defp github_state(:canceled, _live), do: %{"state" => "closed", "state_reason" => "not_planned"}
  defp github_state(:duplicate, _live), do: %{"state" => "closed", "state_reason" => "duplicate"}
  defp github_state(_open, %{"state" => "closed"}), do: %{"state" => "open", "state_reason" => "reopened"}
  defp github_state(_open, _live), do: %{}

  defp relabel(_token, _project, _issue, _live, false, _kind), do: :ok

  defp relabel(token, project, %Issue{} = issue, live, true, kind),
    do: swap_label(token, project, issue, live, kind, Map.fetch!(issue, kind))

  # Adds the label for `value` of `kind` (`:state` or `:priority`) and takes off the others of that kind.
  defp swap_label(token, %Project{github_repo: repo}, %Issue{number: number}, live, kind, value) do
    on_issue = Enum.map(live["labels"] || [], & &1["name"])
    kind_labels = Enum.filter(github_issue_labels(), &Map.fetch!(&1, kind))
    %{name: wanted} = Enum.find(kind_labels, &(Map.fetch!(&1, kind) == value))
    stale = for %{name: name} <- kind_labels, name != wanted, name in on_issue, do: name

    with {:ok, _labels} <- GitHub.add_labels(token, repo, number, [wanted]) do
      Enum.reduce_while(stale, :ok, fn name, :ok ->
        case GitHub.remove_label(token, repo, number, name) do
          {:ok, _labels} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp reassign(_token, _project, _issue, false, _previous_owner), do: :ok

  defp reassign(token, %Project{github_repo: repo}, %Issue{owner_user: owner} = issue, true, previous_owner) do
    unassigned =
      if previous_owner && previous_owner.id != (owner && owner.id),
        do: GitHub.remove_assignees(token, repo, issue.number, [previous_owner.login]),
        else: {:ok, nil}

    with {:ok, _unassigned} <- unassigned,
         {:ok, _assigned} <-
           if(owner, do: GitHub.add_assignees(token, repo, issue.number, [owner.login]), else: {:ok, nil}) do
      :ok
    end
  end

  defp quote_lines(body), do: body |> String.split("\n") |> Enum.take(3) |> Enum.map_join("\n", &("> " <> &1))
end
