defmodule Rail.Issues.Tracker.Local do
  @moduledoc """
  Issues kept in Rail alone. The `issues` and `issue_comments` rows are the tickets, Postgres numbers and names each
  issue as it is inserted, and with no webhook to come back every status move writes the row itself.
  """
  @behaviour Rail.Issues.Tracker

  import Rail.Issues.Utils.WriteIssueStatus

  alias Rail.Issues.Clients.R2
  alias Rail.Issues.Schemas.Comment
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users.Schemas.User

  @ranks %{triage: 0, backlog: 1, todo: 2, in_progress: 3, in_review: 4, done: 5}
  @statuses [:triage, :backlog, :todo, :in_progress, :in_review, :done, :canceled, :duplicate]
  @asset_name ~r/\A[0-9a-f]{8}-[0-9a-f-]{27}-[\w.-]+\z/

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

  # A fresh id per upload, so a re-recorded demo gets a new address and no browser shows its cached copy of the old.
  @impl true
  def upload_asset(%Issue{id: issue_id}, filename, content_type, data_binary) do
    name = "#{Ecto.UUID.generate()}-#{filename}"

    with :ok <- R2.put_object("#{issue_id}/#{name}", content_type, data_binary),
         do: {:ok, RailWeb.Endpoint.url() <> "/issues/#{issue_id}/assets/#{name}"}
  end

  # Only a name in the shape uploads write, so no path reaches another issue's file or a listing of the bucket.
  @impl true
  def get_asset(%Issue{id: issue_id}, name) do
    if Regex.match?(@asset_name, name),
      do: R2.get_object("#{issue_id}/#{name}"),
      else: {:error, :not_found}
  end

  @impl true
  def get_cycles(%Project{}), do: {:ok, %{cycles: [], statuses: []}}

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
