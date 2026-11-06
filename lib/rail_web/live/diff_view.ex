defmodule RailWeb.Live.DiffView do
  @moduledoc """
  The diff pane and everything it holds, the task page's Diff item: the whole branch, the uncommitted work or
  one commit against its first parent, picked in the toolbar, with the reader's comments, which the Review
  tray sends. A merge's view takes no comments.

  The diff is read off the worktree on mount, when the page asks with `reload`, and when HEAD or the
  worktree's status has moved since; a file whose digest has not moved keeps its highlighting. Marking a
  file read is per person and pinned to the file as it was read. Each part of the pane is an assign of its
  own, so an event's reply redraws every part it moved and no other.

  A merge puts the diff away: the header's Merge says so with `merging` before it starts, and a task merging
  or merged keeps it away. The browser walks every row of a large diff each time the page around it changes,
  which a merge does several times; a refused merge brings it back.
  """
  use RailWeb, :live_component

  import RailWeb.Utils.CalculateDiffPane

  alias Rail.Git
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.DiffComment
  alias Rail.Pipeline.Schemas.Task

  # Another of the reader's tabs saved, removed, sent or resolved comments. Only
  # they moved, so the diff is not read again.
  @impl true
  def update(%{reload_comments: true}, socket) do
    socket = if put_away?(socket.assigns), do: socket, else: socket |> assign_comments() |> sync_pane()

    {:ok, socket}
  end

  # The page saw the worktree move under a run, which a status that did not change can hide.
  def update(%{reload: true}, socket) do
    socket = if socket.assigns.loading? or put_away?(socket.assigns), do: socket, else: load_diff(socket)

    {:ok, socket}
  end

  # Sent by Merge before the merge starts, so the diff leaves the page ahead of the merge's own redraws.
  def update(%{merging: merging}, socket) do
    socket = socket |> assign(:merging, merging) |> refresh()

    {:ok, socket}
  end

  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:opened, fn -> nil end)
      |> assign_new(:view, fn -> :branch end)
      |> assign_new(:wrap, fn -> :scroll end)
      |> assign_new(:query, fn -> "" end)
      |> assign_new(:show_files, fn -> true end)
      |> assign_new(:collapsed, fn -> [] end)
      |> assign_new(:auto_collapsed, fn -> MapSet.new() end)
      |> assign_new(:selected_file, fn -> nil end)
      |> assign_new(:expanded_gaps, fn -> %{} end)
      |> assign_new(:highlighted, fn -> %{} end)
      |> assign_new(:files, fn -> [] end)
      |> assign_new(:history, fn -> nil end)
      |> assign_new(:dirty?, fn -> false end)
      |> assign_new(:fingerprint, fn -> :unread end)
      |> assign_new(:comments, fn -> [] end)
      |> assign_new(:open_comments, fn -> [] end)
      |> assign_new(:comment_list, fn -> :files end)
      |> assign_new(:selected_comment, fn -> nil end)
      |> assign_new(:draft, fn -> nil end)
      |> assign_new(:loading?, fn -> true end)
      |> assign_new(:merging, fn -> false end)

    socket = if socket.assigns.focus_file, do: assign(socket, :selected_file, socket.assigns.focus_file), else: socket
    {socket, picked?} = open(socket)

    {:ok, refresh(socket, picked?)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="diff-view" data-qa="diff_view" class="h-full flex flex-col min-h-0">
      <div
        :if={@put_away}
        id="diff-put-away"
        data-qa="diff_put_away"
        class="flex-1 flex flex-col items-center justify-center text-center p-8"
      >
        <.icon name="pi-git-merge" class="w-12 h-12 text-slate-400 dark:text-slate-500 mb-3" />
        <p class="text-sm font-medium text-slate-900 dark:text-slate-100">
          {if Task.finalize_state(@task) == :merged,
            do: "Merged into #{@task.project.default_branch}.",
            else: "Merging into #{@task.project.default_branch}."}
        </p>
        <p class="mt-1 text-sm text-slate-500 dark:text-slate-400">
          {if Task.finalize_state(@task) == :merged,
            do: "The pull request keeps the diff.",
            else: "The diff comes back if GitHub refuses the merge."}
        </p>
        <.link
          :if={@task.pr_url}
          href={@task.pr_url}
          target="_blank"
          rel="noopener"
          class="mt-3 text-sm font-medium text-blue-600 dark:text-blue-400 hover:underline"
        >
          Open the pull request
        </.link>
      </div>

      <div
        :if={@loading? and not @put_away}
        id="diff-loading"
        data-qa="diff_loading"
        aria-busy="true"
        class="h-full space-y-3 p-6"
      >
        <div class="h-4 w-1/3 rounded bg-slate-200 dark:bg-slate-800 motion-safe:animate-pulse" />
        <div
          :for={width <- ["w-full", "w-11/12", "w-4/5"]}
          class={["h-2.5 rounded bg-slate-100 dark:bg-slate-800/60 motion-safe:animate-pulse", width]}
        />
      </div>

      <div :if={not @loading? and not @put_away} class="flex-1 min-h-0">
        <.diff_pane
          frame={@frame}
          toolbar={@toolbar}
          tree={@tree}
          sections={@sections}
          reader_id={@current_scope.user.id}
          target={@myself}
        />
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("pick_commit", %{"commit" => picked}, socket) do
    view =
      case picked do
        "branch" -> :branch
        "uncommitted" -> :uncommitted
        sha -> if Enum.any?(socket.assigns.history.commits, &(&1.sha == sha)), do: {:commit, sha}
      end

    socket = if view, do: socket |> new_view(view) |> load_diff(), else: socket

    {:noreply, socket}
  end

  # The browser wraps the lines itself, so only the toolbar's pressed option moves.
  # Kept on this socket alone: it is this browser's choice, not the task's.
  def handle_event("select_diff_wrap", %{"wrap" => wrap}, socket) do
    socket = socket |> assign(:wrap, if(wrap == "wrap", do: :wrap, else: :scroll)) |> sync_pane()

    {:noreply, socket}
  end

  def handle_event("filter_diff_files", %{"query" => query}, socket) do
    socket = socket |> assign(:query, query) |> sync_pane()

    {:noreply, socket}
  end

  def handle_event("toggle_file_list", _params, socket) do
    socket = socket |> assign(:show_files, not socket.assigns.show_files) |> sync_pane()

    {:noreply, socket}
  end

  def handle_event("toggle_collapsed", %{"path" => path}, socket) do
    collapsed = toggle(socket.assigns.collapsed, path, path not in socket.assigns.collapsed)

    socket = socket |> assign(:collapsed, collapsed) |> sync_pane()

    {:noreply, socket}
  end

  # Picking a file is asking to read it, so it is put in front of the reader and
  # opened if it was folded away.
  def handle_event("select_diff_file", %{"path" => path}, socket) do
    socket =
      socket
      |> assign(:selected_file, path)
      |> assign(:collapsed, toggle(socket.assigns.collapsed, path, false))
      |> push_event("diff:scroll_to", %{path: path})
      |> sync_pane()

    {:noreply, socket}
  end

  # Reading a file is also done with it, so it folds away and the reader moves on to
  # the next unread one. Only the mark moved, so the diff is not read again.
  def handle_event("toggle_viewed", %{"path" => path, "digest" => digest}, socket) do
    read_already? = Enum.any?(socket.assigns.files, &(&1.path == path and &1.viewed?))

    {:ok, _marked} =
      Git.set_file_viewed(socket.assigns.current_scope, socket.assigns.task, :diff, path, digest, not read_already?)

    # A click from a page drawn before the last refresh marks the version it saw,
    # which is only this one if the digest still matches.
    files =
      Enum.map(socket.assigns.files, fn file ->
        if file.path == path, do: %{file | viewed?: not read_already? and file.digest == digest}, else: file
      end)

    socket =
      socket
      |> assign(:collapsed, toggle(socket.assigns.collapsed, path, not read_already?))
      |> fold_away_read_files(files)
      |> assign(:files, files)

    socket = if read_already?, do: socket, else: go_to_next_unread(socket, path)

    {:noreply, sync_pane(socket)}
  end

  # Only a file this pane drew is read, since the path comes from the page; a commit's
  # gap is read as the file was at that commit.
  def handle_event("expand_gap", params, socket) do
    %{"path" => path, "gap_index" => index, "start_line" => start_line, "end_line" => end_line} = params

    case Enum.find(socket.assigns.files, &(&1.path == path)) do
      %{} ->
        {key, lines} =
          Git.expand_diff_gap(
            socket.assigns.task,
            path,
            String.to_integer(index),
            String.to_integer(start_line),
            String.to_integer(end_line),
            revision(socket.assigns.view)
          )

        socket = socket |> assign(:expanded_gaps, Map.put(socket.assigns.expanded_gaps, key, lines)) |> sync_pane()

        {:noreply, socket}

      nil ->
        {:noreply, socket}
    end
  end

  # The line and its code are read off the diff this pane drew, so the comment quotes
  # what the reader saw. The numbers come from the page, and may be stale or not numbers.
  def handle_event("open_diff_comment", %{"path" => path, "kind" => kind} = params, socket) do
    number = if kind == "deleted", do: params["old_line"], else: params["new_line"]
    rows = socket.assigns.files |> Enum.filter(&(&1.path == path)) |> Enum.flat_map(& &1.rows)

    row =
      with true <- commentable?(socket.assigns),
           {line, ""} <- Integer.parse(number || "") do
        Enum.find(rows, &(&1.kind == :line and to_string(&1.line_kind) == kind and line_number(&1) == line))
      end

    socket =
      case row do
        %{line_kind: line_kind, text: text} ->
          draft =
            Map.merge(written_in(socket.assigns.view), %{
              path: path,
              line_kind: line_kind,
              line: line_number(row),
              line_text: text,
              context_text: DiffComment.calculate_context_text(rows, row)
            })

          socket |> assign(:draft, draft) |> sync_pane()

        _no_such_line ->
          socket
      end

    {:noreply, socket}
  end

  def handle_event("cancel_diff_comment", _params, socket) do
    socket = socket |> assign(:draft, nil) |> sync_pane()

    {:noreply, socket}
  end

  def handle_event("change_diff_comment", _params, %{assigns: %{draft: nil}} = socket), do: {:noreply, socket}

  # What is typed is kept, so the file being drawn again does not lose it.
  def handle_event("change_diff_comment", %{"body" => body}, socket) do
    socket = socket |> assign(:draft, Map.put(socket.assigns.draft, :body, body)) |> sync_pane()

    {:noreply, socket}
  end

  def handle_event("save_diff_comment", _params, %{assigns: %{draft: nil}} = socket), do: {:noreply, socket}

  # A blank comment is refused and the composer stays open on what was typed.
  # The list is read back so it is in the order a reload would show it.
  def handle_event("save_diff_comment", %{"body" => body}, socket) do
    %{current_scope: scope, task: task, draft: draft} = socket.assigns

    case Pipeline.create_diff_comment(scope, task, Map.put(draft, :body, body)) do
      {:ok, _comment} ->
        socket = socket |> assign_comments() |> assign(:draft, nil) |> sync_pane()

        {:noreply, socket}

      {:error, _changeset} ->
        {:noreply, socket}
    end
  end

  # Read back rather than dropped from the list, since another tab may have sent it.
  def handle_event("remove_diff_comment", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.comments, &(&1.id == id and &1.status == :unsent)) do
      %{} = comment ->
        {:ok, _removed} = Pipeline.delete_diff_comment(socket.assigns.current_scope, comment)
        socket = socket |> assign_comments() |> sync_pane()

        {:noreply, socket}

      nil ->
        {:noreply, socket}
    end
  end

  # Only a comment's author resolves it. One found unsent or gone was clicked on a
  # stale page, which reading the list again puts right.
  def handle_event("resolve_diff_comment", %{"id" => id, "resolved" => resolved}, socket) do
    %{comments: comments, current_scope: %{user: %{id: user_id}}} = socket.assigns

    case Enum.find(comments, &(&1.id == id and &1.user_id == user_id)) do
      %{} = comment ->
        {_outcome, _comment_or_reason} =
          Pipeline.set_diff_comment_resolved(socket.assigns.current_scope, comment, resolved == "true")

        socket =
          socket
          |> assign(:open_comments, List.delete(socket.assigns.open_comments, id))
          |> assign_comments()
          |> sync_pane()

        {:noreply, socket}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("toggle_diff_comment", %{"id" => id}, socket) do
    socket =
      socket
      |> assign(:open_comments, toggle(socket.assigns.open_comments, id, id not in socket.assigns.open_comments))
      |> sync_pane()

    {:noreply, socket}
  end

  def handle_event("select_diff_list", %{"list" => list}, socket) do
    socket = socket |> assign(:comment_list, if(list == "comments", do: :comments, else: :files)) |> sync_pane()

    {:noreply, socket}
  end

  def handle_event("select_diff_comment", %{"id" => id}, socket), do: {:noreply, select_comment(socket, id)}

  # The first page is thrown away once the live view connects, so reading and
  # highlighting the diff for it would be doing the slowest part twice. A diff put
  # away is not read at all.
  defp refresh(socket, picked? \\ false) do
    put_away = put_away?(socket.assigns)
    socket = assign(socket, :put_away, put_away)

    cond do
      not connected?(socket) or put_away ->
        socket

      picked? and is_binary(socket.assigns.open[:comment]) ->
        socket |> load_diff(true) |> select_comment(socket.assigns.open.comment)

      picked? or socket.assigns.fingerprint != fingerprint(socket.assigns.task) ->
        load_diff(socket, picked?)

      true ->
        sync_pane(socket)
    end
  end

  defp put_away?(%{merging: merging, task: task}), do: merging or Task.finalize_state(task) in [:merging, :merged]

  # A link from a finding names a commit and a file, and one from the Comments item a view and a comment; each new
  # one is followed once.
  defp open(%{assigns: %{open: %{at: at} = open, opened: opened}} = socket) when at != opened do
    view = open[:view] || if(is_binary(open[:commit]), do: {:commit, open.commit}, else: :branch)
    {socket |> new_view(view) |> assign(:opened, at), true}
  end

  defp open(socket), do: {socket, false}

  # What one view had open or folded means nothing in another.
  defp new_view(socket, view) do
    socket
    |> assign(:view, view)
    |> assign(:expanded_gaps, %{})
    |> assign(:collapsed, [])
    |> assign(:auto_collapsed, MapSet.new())
    |> assign(:selected_file, socket.assigns.focus_file)
    |> assign(:draft, nil)
  end

  # A commit the branch no longer has, after a rebase say, is the whole branch again.
  defp load_diff(socket, followed? \\ false) do
    %{current_scope: scope, task: task, highlighted: highlighted} = socket.assigns
    history = Git.load_branch_history(task, for(%{head: head} <- Pipeline.read_review(task), is_binary(head), do: head))

    view =
      with {:commit, sha} <- socket.assigns.view,
           false <- Enum.any?(history.commits, &(&1.sha == sha)) do
        :branch
      else
        _known -> socket.assigns.view
      end

    previous = Enum.concat(Map.values(highlighted))
    files = diff(scope, task, view, previous)

    # A link names the commit a round read, or the uncommitted changes a comment was written in, which need not touch
    # the file the reader came for; the branch has it.
    {view, files} =
      if followed? and lacks_file?(view, files, socket.assigns.focus_file),
        do: {:branch, diff(scope, task, :branch, previous)},
        else: {view, files}

    present? = Task.worktree_present?(task)

    socket
    |> assign(:view, view)
    |> assign(:history, history)
    |> assign(:dirty?, present? and Git.worktree_dirty?(task.worktree_path))
    |> assign(:fingerprint, fingerprint(task))
    |> fold_away_read_files(files)
    |> assign(:files, files)
    |> assign(:highlighted, highlighted |> Map.take([:branch]) |> Map.put(view, files))
    |> assign_comments()
    |> assign(:loading?, false)
    |> sync_pane()
  end

  defp lacks_file?(view, files, file) when view != :branch and is_binary(file),
    do: not Enum.any?(files, &(&1.path == file))

  defp lacks_file?(_view, _files, _file), do: false

  # Jumping to a comment is asking to read it, so whatever would hide it is undone:
  # its file's fold, its own fold if resolved, and a filter its file falls outside.
  defp select_comment(socket, id) do
    %{comments: comments, query: query} = socket.assigns

    case Enum.find(comments, &(&1.id == id)) do
      %{path: path} = comment ->
        hidden? = not String.contains?(String.downcase(path), String.downcase(query))

        socket
        |> assign(:selected_comment, id)
        |> assign(:collapsed, toggle(socket.assigns.collapsed, path, false))
        |> assign(:open_comments, toggle(socket.assigns.open_comments, id, comment.status == :resolved))
        |> assign(:query, if(hidden?, do: "", else: query))
        |> push_event("diff:scroll_to", %{id: "diff-comment-#{id}"})
        |> sync_pane()

      nil ->
        socket
    end
  end

  defp sync_pane(socket) do
    pane = socket.assigns |> pane_state() |> calculate_diff_pane()

    socket
    |> assign(:frame, pane.frame)
    |> assign(:toolbar, pane.toolbar)
    |> assign(:tree, pane.tree)
    |> assign(:sections, pane.sections)
  end

  defp pane_state(assigns) do
    %{
      files: assigns.files,
      filter: assigns.view,
      task_id: assigns.task.id,
      picker: %{
        view: assigns.view,
        history: assigns.history,
        dirty?: assigns.dirty?,
        parent: picked(assigns)
      },
      wrap: assigns.wrap,
      query: assigns.query,
      show_file_tree: assigns.show_files,
      collapsed: assigns.collapsed,
      expanded_gaps: assigns.expanded_gaps,
      selected_file: assigns.selected_file,
      scroll_to: assigns.focus_file,
      target: assigns.myself,
      empty_message: empty_message(assigns.view),
      comments: assigns.comments,
      reader_id: assigns.current_scope.user.id,
      open_comments: assigns.open_comments,
      comment_list: assigns.comment_list,
      selected_comment: assigns.selected_comment,
      draft: assigns.draft,
      commentable?: commentable?(assigns)
    }
  end

  # A comment only stays unfolded while it is resolved, so one resolved again later
  # comes back folded.
  defp assign_comments(socket) do
    %{current_scope: scope, task: task, open_comments: open} = socket.assigns
    comments = Pipeline.list_diff_comments(scope, task)
    resolved = for %{status: :resolved, id: id} <- comments, do: id

    socket |> assign(:comments, comments) |> assign(:open_comments, Enum.filter(open, &(&1 in resolved)))
  end

  defp picked(%{view: {:commit, sha}, history: %{commits: commits}}), do: Enum.find(commits, &(&1.sha == sha))
  defp picked(_assigns), do: nil

  # A merge is main's changes arriving, which nobody on this branch wrote or can answer for.
  defp commentable?(assigns), do: not match?(%{merge?: true}, picked(assigns))

  defp revision({:commit, sha}), do: sha
  defp revision(_worktree), do: :worktree

  defp written_in({:commit, sha}), do: %{filter: :commit, commit: sha}
  defp written_in(filter), do: %{filter: filter}

  defp fingerprint(%Task{worktree_path: worktree_path} = task) do
    if Task.worktree_present?(task), do: Git.branch_fingerprint(worktree_path)
  end

  # A file already read is folded away the first time it is seen that way, and
  # only then: a reader who opens one again has it stay open. The engineer
  # touching it makes it unread, which lets it fold again on the next pass.
  defp fold_away_read_files(socket, files) do
    {read, unread} = Enum.split_with(files, & &1.viewed?)
    # The file a finding sent the reader here for stays open however read it is:
    # folding it away is folding away the thing they came to look at.
    fresh =
      Enum.reject(read, fn file ->
        MapSet.member?(socket.assigns.auto_collapsed, file.path) or file.path == socket.assigns.focus_file
      end)

    socket
    |> assign(:collapsed, Enum.uniq(Enum.map(fresh, & &1.path) ++ socket.assigns.collapsed))
    |> assign(:auto_collapsed, forget(socket.assigns.auto_collapsed, read, unread))
  end

  defp forget(auto_collapsed, read, unread) do
    auto_collapsed
    |> MapSet.union(MapSet.new(read, & &1.path))
    |> MapSet.difference(MapSet.new(unread, & &1.path))
  end

  defp diff(scope, task, view, previous_files) do
    case Git.load_diff(scope, task, view, previous_files) do
      {:ok, files} -> files
      {:error, :no_worktree} -> []
    end
  end

  # The first unread file after the one just read, wrapping round to the top so
  # one skipped earlier is not left behind.
  defp go_to_next_unread(socket, path) do
    {before, after_read} = Enum.split_while(socket.assigns.files, &(&1.path != path))

    case Enum.find(after_read ++ before, &(not &1.viewed?)) do
      %{path: next} ->
        socket
        |> assign(:selected_file, next)
        |> assign(:collapsed, toggle(socket.assigns.collapsed, next, false))
        |> push_event("diff:scroll_to", %{path: next})

      nil ->
        socket
    end
  end

  # A removed line has only its old number; every other line is known by its new one.
  defp line_number(%{line_kind: :deleted, old_line: line}), do: line
  defp line_number(%{new_line: line}), do: line

  defp toggle(paths, path, true), do: Enum.uniq([path | paths])
  defp toggle(paths, path, false), do: List.delete(paths, path)

  defp empty_message(:uncommitted), do: "Everything in the worktree is committed."
  defp empty_message(:branch), do: "Nothing has been changed on this branch yet."
  defp empty_message({:commit, _sha}), do: "This commit changed nothing that can be shown."
end
