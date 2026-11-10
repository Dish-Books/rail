defmodule Rail.Issues.Tracker.Local do
  @moduledoc """
  Issues kept in Rail alone. The `issues` and `issue_comments` rows are the tickets, Postgres numbers and names each
  issue as it is inserted, and with no webhook to come back every status move writes the row itself. Its cycles are
  the `cycles` rows, which `Rail.Issues.close_cycle_day/1` schedules and records.
  """
  @behaviour Rail.Issues.Tracker

  import Ecto.Query
  import Rail.Issues.Utils.WriteIssueStatus

  alias Rail.Issues.Schemas.Comment
  alias Rail.Issues.Schemas.Cycle
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users.Schemas.User

  @ranks %{triage: 0, backlog: 1, todo: 2, in_progress: 3, in_review: 4, done: 5}
  @statuses [:triage, :backlog, :todo, :in_progress, :in_review, :done, :canceled, :duplicate]
  # Linear's type for each, which `Issue.calculate_status_groups/3` orders the groups by.
  @status_types %{
    triage: "triage",
    backlog: "backlog",
    todo: "unstarted",
    in_progress: "started",
    in_review: "started",
    done: "completed",
    canceled: "canceled",
    duplicate: "canceled"
  }

  # The id is drawn here because the URL names it, and the identifier is unknown until Postgres numbers the row.
  @impl true
  def create_issue(_scope, %Project{}, %{state: state} = attrs) do
    id = UXID.generate!(prefix: "iss")

    {:ok,
     Map.merge(status_attrs(state), %{
       id: id,
       external_id: Ecto.UUID.generate(),
       title: attrs[:title],
       description: attrs[:description],
       url: RailWeb.Endpoint.url() <> "/issues/" <> id,
       parent_external_id: attrs[:parent] && attrs[:parent].external_id
     })}
  end

  # The row is already written, so only open pages need telling, after the write commits.
  @impl true
  def update_issue(%Issue{id: id}, _fields, _previous_owner) do
    Phoenix.PubSub.broadcast(Rail.PubSub, "issues", {:issue_changed, id})
  end

  # Judged on the locked row, so a person's cancel while this runs is never moved past. Finished states rank past Done.
  @impl true
  def advance_issue(%Issue{} = issue, target) do
    with {:ok, _issue} <-
           write_issue_status(issue, fn %Issue{state: state} ->
             if Map.get(@ranks, state, 5) >= @ranks[target], do: %{}, else: status_attrs(target)
           end),
         do: :ok
  end

  @impl true
  def create_comment(%Scope{} = scope, %Issue{id: issue_id}, body, parent) do
    author =
      case scope do
        %Scope{user: %User{} = user} ->
          %{author_user_id: user.id, author_name: user.name || user.login, author_avatar_url: user.avatar_url}

        %Scope{} ->
          %{author_name: "Rail"}
      end

    with {:ok, comment} <-
           %Comment{}
           |> Comment.changeset(
             Map.merge(author, %{
               issue_id: issue_id,
               external_id: Ecto.UUID.generate(),
               body: body,
               parent_id: parent && parent.id
             })
           )
           |> Repo.insert() do
      Phoenix.PubSub.broadcast(Rail.PubSub, "issues", {:issue_comments_changed, issue_id})
      {:ok, comment}
    end
  end

  # The issue's own page is where a link would go, and it lists nothing it was not given.
  @impl true
  def link_url(%Issue{}, _url, _title), do: :ok

  # `KEY-12` in any case, or `12`. A key may hold a `-`, so the key is matched whole rather than split off.
  @impl true
  def canonical_identifier(%Project{key: key}, identifier) do
    case Regex.run(~r/\A(?:#{Regex.escape(key)}-)?(\d+)\z/i, identifier) do
      [_identifier, number] -> {:ok, "#{key}-#{String.to_integer(number)}"}
      nil -> :error
    end
  end

  # Rail holds every Rail-tracked issue, so one the database lacks does not exist.
  @impl true
  def fetch_issue(%Project{}, _identifier), do: {:error, :not_found}

  @impl true
  def sync_issues(%Project{}), do: {:error, :unsupported}

  @impl true
  def set_up_project(%Project{}), do: :ok

  @impl true
  def upload_asset(_target, _filename, _content_type, _data_binary), do: {:error, :unsupported}

  @impl true
  def get_asset(%Issue{}, _path), do: {:error, :unsupported}

  # Read as `Tracker.Linear` reads Linear's: the current cycle is the one running, or else the next to start.
  @impl true
  def get_cycles(%Project{id: project_id}) do
    today = Date.utc_today()

    cycles =
      Repo.all(
        from(c in Cycle, where: c.project_id == ^project_id, order_by: [asc: c.starts_on, asc: c.number], preload: :days)
      )

    entries =
      Enum.map(cycles, fn cycle ->
        %{
          id: cycle.id,
          number: cycle.number,
          name: nil,
          starts_on: cycle.starts_on,
          ends_on: cycle.ends_on,
          status: Cycle.calculate_status(cycle, today),
          current: false,
          default_estimate: Cycle.default_estimate(),
          scope_history: Enum.map(cycle.days, & &1.scope),
          started_history: Enum.map(cycle.days, & &1.started),
          completed_history: Enum.map(cycle.days, & &1.completed)
        }
      end)

    current = Enum.find(entries, &(&1.status == :running)) || Enum.find(entries, &(&1.status == :upcoming))

    # Each carries its Rail state, which is what its group's icon shows.
    statuses =
      for {state, position} <- Enum.with_index(@statuses),
          do: %{name: Issue.state_label(state), type: @status_types[state], position: position, state: state}

    {:ok, %{cycles: Enum.map(entries, &%{&1 | current: &1 == current}), statuses: statuses}}
  end

  @impl true
  def get_issue_relations(%Project{}, _external_ids), do: {:ok, %{}}

  @impl true
  def get_statuses(%Project{}) do
    {:ok, Enum.map(@statuses, &%{id: Atom.to_string(&1), name: Issue.state_label(&1), state: &1})}
  end

  # `Rail.Issues.set_issue_status/3` writes these, so the finished hooks fire in one place for every tracker.
  @impl true
  def set_status(_scope, %Issue{}, %{state: state}), do: {:ok, status_attrs(state)}

  @impl true
  def check_assignable(%User{}), do: :ok

  defp status_attrs(state) do
    %{state: state, state_name: Issue.state_label(state), completed_at: if(state == :done, do: DateTime.utc_now(:second))}
  end
end
