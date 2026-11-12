defmodule Rail.Issues.Workers.MoveToLocalTracker do
  @moduledoc """
  Moves a Linear project's tickets into Rail, once. Everything is read from Linear and its files copied to R2 first; then
  one transaction writes the rows `Tracker.Local` reads and flips the project and every ticket onto it.

  Rows are written straight to the tables, as `LinearSync` writes them, so nothing is queued back to a tracker.
  """
  use Oban.Worker,
    queue: :issues,
    max_attempts: 1,
    unique: [keys: [:project_id], states: :incomplete, period: :infinity]

  import Ecto.Query
  import Rail.Issues.Utils.FormatLinearComment
  import Rail.Issues.Utils.FormatLinearIssue

  alias Rail.Issues.Schemas.ClosedCycleIssue
  alias Rail.Issues.Schemas.Comment
  alias Rail.Issues.Schemas.Cycle
  alias Rail.Issues.Schemas.CycleDay
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Schemas.IssueLink
  alias Rail.Issues.Schemas.IssueRelation
  alias Rail.Issues.Tracker.Local
  alias Rail.Linear.Client, as: Linear
  alias Rail.Projects
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Users.Schemas.User

  @upload_url ~r{https://uploads\.linear\.app/[^\s)\]"'<>]+}
  # Well under Postgres's 65,535 parameters a statement, at the twenty-odd columns an issue row has.
  @chunk 500

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
    :archived_at,
    :external_updated_at,
    :cycle_external_id,
    :parent_external_id,
    :updated_at
  ]

  @replace_comment [:issue_id, :parent_id, :author_user_id, :body, :author_name, :author_avatar_url, :updated_at]

  @refs [:issue_external_id, :parent_external_id, :author_linear_id]

  @steps %{
    reading_issues: "reading tickets",
    reading_comments: "reading comments",
    reading_cycles: "reading cycles",
    copying_files: "copying files",
    writing: "writing"
  }

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"project_id" => project_id}} = job) do
    {:ok, project} = Projects.get_project(project_id)

    # Every stop is {:error, {step, reason}}, and the transaction rolls back with the same shape.
    with {:ok, linear} <- read_linear(project),
         ids = issue_ids(linear.issues),
         {:ok, files} <- copy_files(project, linear, ids),
         {:ok, %Project{}} <-
           Repo.transaction(fn -> write(project, linear, ids, files) end, timeout: to_timeout(minute: 10)) do
      Phoenix.PubSub.broadcast(Rail.PubSub, "projects", {:project_changed, project_id})
      Phoenix.PubSub.broadcast(Rail.PubSub, "issues", {:issues_synced, project_id})
      Phoenix.PubSub.broadcast(Rail.PubSub, "cycles", {:cycles_changed, project_id})
      :ok
    else
      {:error, {step, reason}} -> record_failure(job, project, step, reason)
    end
  end

  defp read_linear(%Project{} = project) do
    with {:ok, %{"team" => %{"key" => key}}, issues} <-
           read_pages(:reading_issues, &Linear.export_issues(project, &1), ["team", "issues"]),
         {:ok, _data, comments} <- read_pages(:reading_comments, &Linear.export_comments(project, &1), ["comments"]),
         {:ok, _data, cycles} <- read_pages(:reading_cycles, &Linear.export_cycles(project, &1), ["team", "cycles"]) do
      # A trashed ticket is gone from Linear, and a comment on a ticket the export lacks has nowhere to go.
      issues = Enum.reject(issues, &(&1["trashed"] == true))
      kept = MapSet.new(issues, & &1["id"])
      comments = Enum.filter(comments, &MapSet.member?(kept, get_in(&1, ["issue", "id"])))
      {:ok, %{key: key, issues: issues, comments: comments, cycles: cycles}}
    end
  end

  # The last page's data comes back too, for what the query reads beside the connection.
  defp read_pages(step, fetch, path, cursor \\ nil, pages \\ []) do
    case fetch.(after: cursor) do
      {:ok, data} ->
        %{"nodes" => nodes, "pageInfo" => page_info} = get_in(data, path)
        pages = [nodes | pages]

        if page_info["hasNextPage"],
          do: read_pages(step, fetch, path, page_info["endCursor"], pages),
          else: {:ok, data, pages |> Enum.reverse() |> Enum.concat()}

      {:error, reason} ->
        {:error, {step, reason}}
    end
  end

  # A ticket Rail already holds keeps its id; the rest are drawn now, since their files are stored under them.
  defp issue_ids(issues) do
    external_ids = Enum.map(issues, & &1["id"])
    held = Map.new(Repo.all(from(i in Issue, where: i.external_id in ^external_ids, select: {i.external_id, i.id})))
    Map.new(external_ids, &{&1, held[&1] || UXID.generate!(prefix: "iss")})
  end

  defp copy_files(%Project{} = project, linear, ids) do
    texts =
      Enum.flat_map(linear.issues, fn issue ->
        attachments = for attachment <- get_in(issue, ["attachments", "nodes"]) || [], do: attachment["url"]
        Enum.map([issue["description"] | attachments], &{issue["id"], &1})
      end) ++ Enum.map(linear.comments, &{get_in(&1, ["issue", "id"]), &1["body"]})

    pairs =
      for {external_id, text} <- texts,
          is_binary(text),
          [url] <- Regex.scan(@upload_url, text),
          uniq: true,
          do: {external_id, url}

    identifiers = Map.new(linear.issues, &{&1["id"], &1["identifier"]})

    Enum.reduce_while(pairs, {:ok, %{}}, fn {external_id, url} = pair, {:ok, files} ->
      case copy_file(project, Map.fetch!(ids, external_id), url) do
        {:ok, copied} -> {:cont, {:ok, Map.put(files, pair, copied)}}
        :gone -> {:cont, {:ok, files}}
        {:error, reason} -> {:halt, {:error, {:copying_files, {:file, identifiers[external_id], url, reason}}}}
      end
    end)
  end

  # Stored as a file uploaded to the ticket in Rail would be. One Linear had already lost keeps its old address.
  defp copy_file(%Project{} = project, issue_id, "https://uploads.linear.app/" <> path) do
    filename = path |> String.split("?") |> hd() |> Path.basename()

    case Linear.get_asset(project, path) do
      {:ok, content_type, body} -> Local.upload_asset(%Issue{id: issue_id}, filename, content_type, body)
      {:error, {:linear_api_error, 404, _body}} -> :gone
      {:error, _reason} = error -> error
    end
  end

  defp write(%Project{id: project_id}, linear, ids, files) do
    project = Repo.one!(from(p in Project, where: p.id == ^project_id, lock: "FOR UPDATE"))
    if project.tracker != :linear, do: Repo.rollback({:writing, :left_linear})

    now = DateTime.utc_now()
    today = Date.utc_today()
    states = Map.new(linear.issues, &{&1["id"], calculate_state(&1["state"] || %{})})

    linear_user_ids =
      Enum.map(linear.issues, &get_in(&1, ["assignee", "id"])) ++
        Enum.map(linear.comments, &get_in(&1, ["user", "id"]))

    users = users_by_linear_id(linear_user_ids)
    cycles = insert_cycles(project, linear.cycles, now)
    cycle_ids = Map.new(cycles, &{&1.external_id, &1.id})

    upsert_issues(project, linear.issues, %{
      ids: ids,
      files: files,
      users: users,
      states: states,
      cycle_ids: cycle_ids,
      now: now
    })

    upsert_comments(linear.comments, ids, files, users)
    insert_cycle_days(cycles, today)
    insert_closed_cycle_issues(project, cycles, linear.issues, %{ids: ids, states: states, today: today, now: now})
    {relations, links} = calculate_relations(linear.issues, ids)
    insert_relations(project, relations, now)
    insert_links(linear.issues, links, %{ids: ids, files: files, now: now})
    flip(project, linear.key, now)

    case Projects.switch_to_local_tracker(project, linear.key) do
      {:ok, %Project{} = project} -> project
      {:error, changeset} -> Repo.rollback({:writing, changeset})
    end
  end

  # New Rail ids, with Linear's own numbers, so the numbering trigger leaves them alone. A cycle ends the day before
  # Linear's `endsAt`, as `Tracker.Linear` reads it.
  defp insert_cycles(%Project{id: project_id}, nodes, now) do
    cycles =
      Enum.map(nodes, fn node ->
        %{
          id: UXID.generate!(prefix: "cyc"),
          external_id: node["id"],
          node: node,
          number: trunc(node["number"]),
          completed?: node["completedAt"] != nil,
          starts_on: node["startsAt"] |> DateTime.from_iso8601() |> elem(1) |> DateTime.to_date(),
          ends_on: node["endsAt"] |> DateTime.from_iso8601() |> elem(1) |> DateTime.to_date() |> Date.add(-1)
        }
      end)

    rows =
      Enum.map(cycles, fn cycle ->
        cycle
        |> Map.take([:id, :number, :starts_on, :ends_on])
        |> Map.merge(%{project_id: project_id, inserted_at: now, updated_at: now})
      end)

    insert_chunks(Cycle, rows, [])
    cycles
  end

  defp upsert_issues(%Project{id: project_id}, nodes, %{ids: ids, files: files} = moved) do
    rows =
      Enum.map(nodes, fn node ->
        external_id = node["id"]
        state = Map.fetch!(moved.states, external_id)

        node
        |> format_linear_issue()
        |> Map.merge(%{
          id: Map.fetch!(ids, external_id),
          project_id: project_id,
          tracker: :linear,
          description: rewrite(node["description"], external_id, files),
          state: state,
          state_name: Issue.state_label(state),
          cycle_external_id: Map.get(moved.cycle_ids, get_in(node, ["cycle", "id"])),
          owner_user_id: Map.get(moved.users, get_in(node, ["assignee", "id"])),
          inserted_at: moved.now,
          updated_at: moved.now
        })
      end)

    written =
      insert_chunks(Issue, rows,
        on_conflict: {:replace, @replace_issue},
        conflict_target: :external_id,
        returning: [:id, :external_id]
      )

    # A row written since its files were copied holds another id, which the copies are not stored under.
    with_files = MapSet.new(files, fn {{external_id, _url}, _copied} -> external_id end)

    if Enum.any?(written, &(MapSet.member?(with_files, &1.external_id) and &1.id != ids[&1.external_id])),
      do: Repo.rollback({:writing, :ticket_changed})
  end

  # A reply needs its parent's Rail id, so the threads' first comments go in first.
  defp upsert_comments(nodes, ids, files, users) do
    comments =
      for node <- nodes do
        {refs, attrs} = node |> format_linear_comment() |> Map.split(@refs)
        {refs, %{attrs | body: rewrite(attrs.body, refs.issue_external_id, files)}}
      end

    {replies, top_level} = Enum.split_with(comments, fn {refs, _attrs} -> refs.parent_external_id end)
    parent_ids = write_comments(top_level, ids, users, %{})
    write_comments(replies, ids, users, parent_ids)
  end

  defp write_comments(comments, ids, users, parent_ids) do
    rows =
      for {refs, attrs} <- comments,
          refs.parent_external_id == nil or Map.has_key?(parent_ids, refs.parent_external_id) do
        Map.merge(attrs, %{
          id: UXID.generate!(prefix: "com"),
          issue_id: Map.fetch!(ids, refs.issue_external_id),
          parent_id: Map.get(parent_ids, refs.parent_external_id),
          author_user_id: Map.get(users, refs.author_linear_id)
        })
      end

    Comment
    |> insert_chunks(rows,
      on_conflict: {:replace, @replace_comment},
      conflict_target: :external_id,
      returning: [:id, :external_id]
    )
    |> Map.new(&{&1.external_id, &1.id})
  end

  # Every finished day through yesterday, but a past cycle Linear has not completed leaves its last day to the nightly
  # run, which then closes it. A day past Linear's history repeats its last value.
  defp insert_cycle_days(cycles, today) do
    last_day = Date.add(today, -1)

    rows =
      for cycle <- cycles,
          last =
            if(Date.before?(cycle.ends_on, today) and not cycle.completed?,
              do: Date.add(cycle.ends_on, -1),
              else: Enum.min([cycle.ends_on, last_day], Date)
            ),
          not Date.after?(cycle.starts_on, last),
          {day, index} <- Enum.with_index(Date.range(cycle.starts_on, last)) do
        completed = history_at(cycle.node["completedScopeHistory"], index)

        %{
          id: UXID.generate!(prefix: "cyd"),
          cycle_id: cycle.id,
          day: day,
          scope: history_at(cycle.node["scopeHistory"], index),
          # Linear's in-progress history drops an issue once it is done, and Started counts done work.
          started: history_at(cycle.node["inProgressScopeHistory"], index) + completed,
          completed: completed
        }
      end

    insert_chunks(CycleDay, rows, [])
  end

  # What Rail's own close writes for each cycle Linear has completed: the tickets it still holds, as they stand, and
  # those Linear left unfinished when it closed, as Todo.
  defp insert_closed_cycle_issues(%Project{id: project_id}, cycles, issues, %{ids: ids, today: today} = moved) do
    ended =
      for cycle <- cycles,
          cycle.completed? and Date.before?(cycle.ends_on, today),
          into: %{},
          do: {cycle.external_id, cycle}

    held =
      for issue <- issues,
          %{id: cycle_id} <- [ended[get_in(issue, ["cycle", "id"])]],
          do: {cycle_id, Map.fetch!(ids, issue["id"]), Map.fetch!(moved.states, issue["id"])}

    unfinished =
      for {_external_id, cycle} <- ended,
          %{"id" => external_id} <- get_in(cycle.node, ["uncompletedIssuesUponClose", "nodes"]) || [],
          Map.has_key?(ids, external_id),
          do: {cycle.id, Map.fetch!(ids, external_id), :todo}

    rows =
      (held ++ unfinished)
      |> Enum.uniq_by(fn {cycle_id, issue_id, _state} -> {cycle_id, issue_id} end)
      |> Enum.map(fn {cycle_id, issue_id, state} ->
        %{
          id: UXID.generate!(prefix: "ccl"),
          project_id: project_id,
          cycle_id: cycle_id,
          issue_id: issue_id,
          state: state,
          inserted_at: moved.now
        }
      end)

    insert_chunks(ClosedCycleIssue, rows, [])
  end

  # A blocker inside the project is a relation, and anything else a link to the other ticket's Rail page where Rail
  # holds it.
  defp calculate_relations(issues, ids) do
    related =
      for issue <- issues,
          {field, side, direction} <- [{"relations", "relatedIssue", :out}, {"inverseRelations", "issue", :in}],
          %{"type" => type, ^side => %{"id" => _id} = other} <- get_in(issue, [field, "nodes"]) || [],
          do: {issue, type, direction, other}

    elsewhere = for {_issue, _type, _direction, %{"id" => id}} <- related, not Map.has_key?(ids, id), uniq: true, do: id

    held =
      Map.merge(
        Map.new(Repo.all(from(i in Issue, where: i.external_id in ^elsewhere, select: {i.external_id, i.id}))),
        ids
      )

    {relations, links} =
      Enum.reduce(related, {[], []}, fn {issue, type, direction, other}, {relations, links} ->
        this = Map.fetch!(ids, issue["id"])

        case {type, direction, ids[other["id"]]} do
          {"blocks", :out, other_id} when is_binary(other_id) -> {[{this, other_id} | relations], links}
          {"blocks", :in, other_id} when is_binary(other_id) -> {[{other_id, this} | relations], links}
          _link -> {relations, [relation_link(this, type, direction, other, held) | links]}
        end
      end)

    {Enum.reverse(relations), Enum.reverse(links)}
  end

  # Linear lists each pair from both ends, so a blocker inside the project is written once.
  defp insert_relations(%Project{id: project_id}, relations, now) do
    rows =
      relations
      |> Enum.reject(fn {blocker, blocked} -> blocker == blocked end)
      |> Enum.uniq_by(fn {blocker, blocked} -> Enum.sort([blocker, blocked]) end)
      |> Enum.map(fn {blocker, blocked} ->
        %{
          id: UXID.generate!(prefix: "irl"),
          project_id: project_id,
          blocker_issue_id: blocker,
          blocked_issue_id: blocked,
          inserted_at: now,
          updated_at: now
        }
      end)

    insert_chunks(IssueRelation, rows, on_conflict: :nothing)
  end

  # Linear's attachments first, under their title or else their URL, and no URL twice on one ticket.
  defp insert_links(issues, links, %{ids: ids, files: files, now: now}) do
    attachments =
      for issue <- issues,
          %{"url" => url} = attachment when is_binary(url) <- get_in(issue, ["attachments", "nodes"]) || [] do
        title = if attachment["title"] in [nil, ""], do: url, else: attachment["title"]
        {Map.fetch!(ids, issue["id"]), rewrite(url, issue["id"], files), title}
      end

    rows =
      (attachments ++ links)
      |> Enum.uniq_by(fn {issue_id, url, _title} -> {issue_id, url} end)
      |> Enum.map(fn {issue_id, url, title} ->
        %{
          id: UXID.generate!(prefix: "ilk"),
          issue_id: issue_id,
          url: url,
          title: title,
          inserted_at: now,
          updated_at: now
        }
      end)

    insert_chunks(IssueLink, rows, on_conflict: :nothing, conflict_target: [:issue_id, :url])
  end

  defp relation_link(issue_id, type, direction, %{"id" => other_id} = other, held) do
    url =
      case held[other_id] do
        id when is_binary(id) -> RailWeb.Endpoint.url() <> "/issues/" <> id
        nil -> other["url"]
      end

    {issue_id, url, "#{relation_title(type, direction)} #{other["identifier"]}"}
  end

  defp relation_title("blocks", :out), do: "Blocks"
  defp relation_title("blocks", :in), do: "Blocked by"
  defp relation_title("duplicate", :out), do: "Duplicate of"
  defp relation_title("duplicate", :in), do: "Duplicated by"
  defp relation_title("similar", _direction), do: "Similar to"
  defp relation_title(_related, _direction), do: "Related to"

  # Last, since the numbering trigger renumbers any Rail-tracked row inserted with no number. A row carrying another
  # team's key is here only for its task, so it takes the next number after the highest.
  defp flip(%Project{id: project_id}, key, now) do
    rows =
      Repo.all(
        from(i in Issue,
          where: i.project_id == ^project_id,
          order_by: [asc: i.inserted_at, asc: i.id],
          select: {i.id, i.identifier}
        )
      )

    pattern = ~r/\A#{Regex.escape(key)}-(\d+)\z/

    {numbered, others} =
      Enum.reduce(rows, {[], []}, fn {id, identifier}, {numbered, others} ->
        case Regex.run(pattern, identifier || "") do
          [_identifier, number] -> {[{id, String.to_integer(number), identifier} | numbered], others}
          nil -> {numbered, [id | others]}
        end
      end)

    highest = numbered |> Enum.map(&elem(&1, 1)) |> Enum.max(fn -> 0 end)

    renumbered =
      others |> Enum.reverse() |> Enum.with_index(highest + 1) |> Enum.map(fn {id, n} -> {id, n, "#{key}-#{n}"} end)

    all = numbered ++ renumbered

    Repo.update_all(
      from(i in Issue,
        join:
          v in fragment(
            "SELECT * FROM unnest(?::text[], ?::int[], ?::text[]) AS v(id, number, identifier)",
            ^Enum.map(all, &elem(&1, 0)),
            ^Enum.map(all, &elem(&1, 1)),
            ^Enum.map(all, &elem(&1, 2))
          ),
        on: v.id == i.id,
        where: i.project_id == ^project_id,
        update: [
          set: [
            tracker: ^:local,
            number: v.number,
            identifier: v.identifier,
            url: fragment("? || ?", ^(RailWeb.Endpoint.url() <> "/issues/"), i.id),
            updated_at: ^now
          ]
        ]
      ),
      []
    )
  end

  defp calculate_state(%{} = state) do
    case {state["type"], String.downcase(state["name"] || "")} do
      {"unstarted", _name} -> :todo
      {"started", "in review"} -> :in_review
      {"canceled", "duplicate"} -> :duplicate
      _by_type -> format_linear_issue(%{"state" => state}).state
    end
  end

  defp history_at(history, index) do
    history = history || []
    round(Enum.at(history, index) || List.last(history) || 0)
  end

  defp rewrite(nil, _external_id, _files), do: nil

  defp rewrite(text, external_id, files), do: Regex.replace(@upload_url, text, &Map.get(files, {external_id, &1}, &1))

  defp insert_chunks(schema, rows, opts) do
    rows
    |> Enum.chunk_every(@chunk)
    |> Enum.flat_map(fn chunk ->
      {_count, written} = Repo.insert_all(schema, chunk, opts)
      written || []
    end)
  end

  defp users_by_linear_id(linear_user_ids) do
    ids = linear_user_ids |> Enum.reject(&is_nil/1) |> Enum.uniq()

    from(u in User, where: u.linear_user_id in ^ids, select: {u.linear_user_id, u.id})
    |> Repo.all()
    |> Map.new()
  end

  # The sentence the projects page shows. Written before Oban marks the job, so the page reads it while it still runs.
  defp record_failure(%Oban.Job{id: job_id, meta: meta}, %Project{id: project_id}, step, reason) do
    sentence = calculate_failure(@steps[step], reason)
    Repo.update_all(from(j in Oban.Job, where: j.id == ^job_id), set: [meta: Map.put(meta || %{}, "failure", sentence)])
    Phoenix.PubSub.broadcast(Rail.PubSub, "projects", {:project_changed, project_id})
    {:error, sentence}
  end

  defp calculate_failure(_step, {:file, identifier, url, {:linear_api_error, status, _body}}),
    do: "Linear answered #{status} for a file on #{identifier} (#{url}), so nothing was written."

  defp calculate_failure(step, {:file, _identifier, _url, reason}), do: calculate_failure(step, reason)

  defp calculate_failure(step, {:linear_api_error, status, _body}),
    do: "Linear answered #{status} while #{step}, so nothing was written."

  defp calculate_failure(step, {:linear_graphql_error, [%{"message" => message} | _rest]}),
    do: "Linear refused the request while #{step} (#{message}), so nothing was written."

  defp calculate_failure(_step, :no_workspace_token),
    do: "Rail has no Linear token for this project's workspace, so nothing was written."

  defp calculate_failure(step, {:r2_error, status, _body}),
    do: "Rail's file storage answered #{status} while #{step}, so nothing was written."

  defp calculate_failure(_step, :left_linear), do: "The project had already left Linear, so nothing was written."

  defp calculate_failure(_step, :ticket_changed),
    do: "A ticket changed in Rail while its files were copied, so nothing was written."

  defp calculate_failure(_step, %Ecto.Changeset{} = changeset),
    do: "Another project already has the key #{Ecto.Changeset.get_field(changeset, :key)}, so nothing was written."

  defp calculate_failure(step, %{__exception__: true} = exception),
    do: "The move stopped while #{step} (#{Exception.message(exception)}), so nothing was written."

  defp calculate_failure(step, reason), do: "The move stopped while #{step} (#{inspect(reason)}), so nothing was written."
end
