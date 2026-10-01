defmodule RailWeb.Live.EngineerStage do
  @moduledoc """
  The change the engineer made, where CI stands on it, and the two decisions a
  human takes on it.

  The diff is read off the worktree every time, because it is the worktree that
  moved and no row records that, but a file whose digest has not moved keeps the
  highlighting it was already given. Two views of it: everything on the branch, which
  is what review means, and only what is uncommitted, which is what "what has it
  changed since I last looked" means. Marking a file read is per person and
  pinned to the file as it was read, so a file the engineer touches again comes
  back unread. Comments on lines are the reader's own until they send them all to
  the engineer as one message.
  """
  use RailWeb, :live_component

  import RailWeb.Utils.CalculateDiffPane

  alias Rail.Git
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias RailWeb.Live.DiffFile
  alias RailWeb.Live.DiffFileTree
  alias RailWeb.Live.DiffToolbar

  # Another of the reader's tabs saved, removed or sent comments. Only they moved,
  # so the diff is not read again.
  @impl true
  def update(%{reload_comments: true}, socket) do
    %{current_scope: scope, task: task} = socket.assigns
    socket = socket |> assign(:comments, Pipeline.list_diff_comments(scope, task)) |> sync_pane()

    {:ok, socket}
  end

  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:error, fn -> nil end)
      |> assign_new(:committing, fn -> false end)
      |> assign_new(:filter, fn -> :branch end)
      |> assign_new(:query, fn -> "" end)
      |> assign_new(:show_files, fn -> true end)
      |> assign_new(:collapsed, fn -> [] end)
      |> assign_new(:auto_collapsed, fn -> MapSet.new() end)
      |> assign_new(:selected_file, fn -> nil end)
      |> assign_new(:expanded_gaps, fn -> %{} end)
      |> assign_new(:highlighted, fn -> %{} end)
      |> assign_new(:drawn, fn -> nil end)
      |> assign_new(:sent, fn -> nil end)
      |> assign_new(:comments, fn -> [] end)
      |> assign_new(:draft, fn -> nil end)

    socket = if socket.assigns.focus_file, do: assign(socket, :selected_file, socket.assigns.focus_file), else: socket
    socket = load_status(socket)

    # The first page is thrown away once the live view connects, so reading and
    # highlighting the diff for it would be doing the slowest part twice. Whether
    # there is any work is still asked, cheaply, so the header does not jump.
    socket =
      if connected?(socket),
        do: load_diff(socket),
        else:
          socket
          |> assign(:loading?, true)
          |> assign(:files, [])
          |> assign(:work?, Git.branch_changed?(socket.assigns.task))
          |> sync_pane()

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="engineer-stage" data-qa="engineer-stage" class="contents">
      <.task_layout
        task={@task}
        run={@run}
        stage_run={@stage_run}
        line={@line}
        title={@task.issue.title}
        flush={@work? or @loading?}
      >
        <:tabs>{render_slot(@tabs)}</:tabs>
        <:actions>
          {render_slot(@actions)}

          <span
            :if={@ci}
            id="ci-status"
            data-qa="ci_status"
            title={ci_title(@ci)}
            class={[
              "inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full text-xs font-semibold",
              ci_tone(@ci.state)
            ]}
          >
            <.icon
              name={ci_icon(@ci.state)}
              class={["size-3.5", @ci.state == :running && "motion-safe:animate-spin"]}
            />
            {ci_label(@ci)}
          </span>

          <button
            :if={@show_run_ci? and not Run.running?(@run)}
            type="button"
            id="run-ci"
            data-qa="run_ci"
            phx-click="run_ci"
            phx-target={@myself}
            class="inline-flex items-center gap-2 px-4 py-2 rounded-lg border border-slate-300 dark:border-slate-600 text-sm font-semibold text-slate-900 dark:text-slate-100 hover:bg-slate-50 dark:hover:bg-slate-800 cursor-pointer"
          >
            {if @ci.state == :failed, do: "Run CI again", else: "Run CI"}
          </button>

          <button
            :if={(@dirty? or @unpushed? or @committing) and not @show_run_ci?}
            type="button"
            id="commit-work"
            data-qa="commit_work"
            phx-click="commit"
            phx-target={@myself}
            disabled={@committing or Run.running?(@run)}
            aria-busy={to_string(@committing)}
            class="inline-flex items-center gap-2 px-4 py-2 rounded-lg border border-slate-300 dark:border-slate-600 text-sm font-semibold text-slate-900 dark:text-slate-100 hover:bg-slate-50 dark:hover:bg-slate-800 cursor-pointer disabled:opacity-50 disabled:cursor-not-allowed"
          >
            <.icon :if={@committing} name="pi-circle-notch" class="size-4 motion-safe:animate-spin" />
            {commit_label(@dirty?, @committing)}
          </button>

          <button
            :if={(@approvable or @changed_since_review?) and @work? and not Run.running?(@run)}
            type="button"
            id="send-to-review"
            data-qa="send_to_review"
            phx-click="send_to_review"
            phx-target={@myself}
            disabled={@committing or not ci_passed?(@ci)}
            title={if not ci_passed?(@ci), do: "CI has to pass on the latest commit first"}
            class="px-4 py-2 rounded-lg text-sm font-semibold bg-blue-600 dark:bg-blue-500 text-white hover:opacity-90 cursor-pointer shadow-xs disabled:opacity-50 disabled:cursor-not-allowed"
          >
            Send to review
          </button>
        </:actions>

        <:alerts :if={@error}>
          <p
            id="engineer-error"
            data-qa="engineer_error"
            class="max-h-32 overflow-auto whitespace-pre-wrap text-xs text-red-600 dark:text-red-500"
          >
            {@error}
          </p>
        </:alerts>

        <.diff_loading :if={@loading?} />

        <.work_pending :if={not @work? and not @loading?} running={Run.running?(@run)} />

        <div :if={@work? and not @loading?} id="engineer-diff" data-qa="engineer_diff" class="h-full">
          <.diff_pane {@drawn} />
        </div>

        <:sidebar>{render_slot(@sidebar)}</:sidebar>
      </.task_layout>
    </div>
    """
  end

  @impl true
  def handle_event("select_diff_filter", %{"filter" => filter}, socket) do
    socket =
      socket
      |> assign(:filter, if(filter == "uncommitted", do: :uncommitted, else: :branch))
      |> assign(:expanded_gaps, %{})
      |> assign(:collapsed, [])
      |> assign(:auto_collapsed, MapSet.new())
      |> assign(:selected_file, nil)
      |> assign(:draft, nil)

    {:noreply, load_diff(socket)}
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
      Git.set_file_viewed(socket.assigns.current_scope, socket.assigns.task, path, digest, not read_already?)

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

  def handle_event("expand_gap", params, socket) do
    %{"path" => path, "gap_index" => index, "start_line" => start_line, "end_line" => end_line} = params

    {key, lines} =
      Git.expand_diff_gap(
        socket.assigns.task,
        path,
        String.to_integer(index),
        String.to_integer(start_line),
        String.to_integer(end_line)
      )

    socket = socket |> assign(:expanded_gaps, Map.put(socket.assigns.expanded_gaps, key, lines)) |> sync_pane()

    {:noreply, socket}
  end

  # The line is read off the diff this pane drew, so the comment quotes what the
  # reader saw. The numbers come from the page, which may be stale or not numbers.
  def handle_event("open_diff_comment", %{"path" => path, "kind" => kind} = params, socket) do
    number = if kind == "deleted", do: params["old_line"], else: params["new_line"]

    row =
      with {line, ""} <- Integer.parse(number || "") do
        socket.assigns.files
        |> Enum.filter(&(&1.path == path))
        |> Enum.flat_map(& &1.rows)
        |> Enum.find(&(&1.kind == :line and to_string(&1.line_kind) == kind and line_number(&1) == line))
      end

    socket =
      case row do
        %{line_kind: line_kind, text: text} ->
          draft = %{
            path: path,
            line_kind: line_kind,
            line: line_number(row),
            line_text: text,
            filter: socket.assigns.filter
          }

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
        socket =
          socket
          |> assign(:comments, Pipeline.list_diff_comments(scope, task))
          |> assign(:draft, nil)
          |> sync_pane()

        {:noreply, socket}

      {:error, _changeset} ->
        {:noreply, socket}
    end
  end

  def handle_event("remove_diff_comment", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.comments, &(&1.id == id)) do
      %{} = comment ->
        {:ok, _removed} = Pipeline.delete_diff_comment(socket.assigns.current_scope, comment)
        socket = socket |> assign(:comments, List.delete(socket.assigns.comments, comment)) |> sync_pane()

        {:noreply, socket}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("send_diff_comments", _params, socket) do
    case Pipeline.send_diff_comments(socket.assigns.current_scope, socket.assigns.run) do
      {:ok, _delivery, _run} ->
        send(self(), :task_changed)
        socket = socket |> assign(:comments, []) |> assign(:error, nil) |> sync_pane()

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, assign(socket, :error, message_for(reason))}
    end
  end

  # A push runs the repository's own pre-push hooks, which can take minutes, so it
  # goes off the LiveView process and the button says it is in flight. A second
  # click while it is would only race the first.
  def handle_event("commit", _params, %{assigns: %{committing: true}} = socket), do: {:noreply, socket}

  def handle_event("commit", _params, socket) do
    %{current_scope: scope, run: run} = socket.assigns

    socket =
      socket
      |> assign(:committing, true)
      |> assign(:error, nil)
      |> start_async(:commit, fn ->
        # Unlinked, so leaving the page does not cut a commit off between its go-ahead
        # and the push, CI or review that settles it.
        Rail.TaskSupervisor
        |> Elixir.Task.Supervisor.async_nolink(fn -> Pipeline.commit_and_send_to_review(scope, run) end)
        |> Elixir.Task.await(:infinity)
      end)

    {:noreply, socket}
  end

  def handle_event("run_ci", _params, socket) do
    case Pipeline.run_ci(socket.assigns.current_scope, socket.assigns.run) do
      {:ok, _run} ->
        send(self(), :task_changed)
        {:noreply, assign(socket, :error, nil)}

      {:error, reason} ->
        {:noreply, assign(socket, :error, message_for(reason))}
    end
  end

  def handle_event("send_to_review", _params, socket) do
    case Pipeline.send_to_review(socket.assigns.run) do
      {:ok, _run} ->
        send(self(), :task_changed)
        {:noreply, assign(socket, :error, nil)}

      {:error, reason} ->
        {:noreply, assign(socket, :error, message_for(reason))}
    end
  end

  # Committing is also how a run that failed to commit is retried, so what it
  # clears is the run's error as well as this component's. Failing half way
  # still moved the worktree, so either way the pane re-reads it: what is left
  # outstanding is what the button offers next.
  @impl true
  def handle_async(:commit, {:ok, {:ok, _run}}, socket) do
    {:ok, _cleared} = Pipeline.update_run(socket.assigns.run, %{error: nil})
    send(self(), :task_changed)

    socket = socket |> assign(:committing, false) |> assign(:error, nil) |> load_status() |> load_diff()

    {:noreply, socket}
  end

  def handle_async(:commit, {:ok, {:error, reason}}, socket) do
    socket = socket |> assign(:committing, false) |> assign(:error, message_for(reason)) |> load_status() |> load_diff()

    {:noreply, socket}
  end

  def handle_async(:commit, {:exit, reason}, socket) do
    socket = socket |> assign(:committing, false) |> assign(:error, message_for(reason)) |> load_status() |> load_diff()

    {:noreply, socket}
  end

  attr :running, :boolean, required: true

  # Nothing to read yet. While the engineer works, this says what is coming; once
  # it has stopped, the chat is where it resumes.
  defp work_pending(assigns) do
    ~H"""
    <div
      id="engineer-work-pending"
      data-qa="engineer_work_pending"
      class="flex flex-col items-center gap-10 py-10"
    >
      <div class="flex flex-col items-center text-center max-w-md">
        <div class="relative flex items-center justify-center size-14 rounded-2xl bg-blue-50 dark:bg-blue-950 text-blue-600 dark:text-blue-400 ring-1 ring-blue-100 dark:ring-blue-900">
          <span
            :if={@running}
            class="absolute inset-0 rounded-2xl ring-2 ring-blue-400/40 motion-safe:animate-ping"
          />
          <.icon name={if @running, do: "pi-terminal-window", else: "pi-code"} class="size-7" />
        </div>

        <h2
          id="engineer-work-pending-title"
          class="mt-5 text-base font-semibold text-slate-900 dark:text-slate-100"
        >
          {if @running, do: "Building the implementation", else: "Nothing changed yet"}
        </h2>

        <p :if={@running} class="mt-2 text-sm leading-relaxed text-slate-500 dark:text-slate-400">
          The engineer is working through the approved plan in its own worktree.
          The diff appears here as soon as there is something to read.
        </p>

        <p :if={not @running} class="mt-2 text-sm leading-relaxed text-slate-500 dark:text-slate-400">
          The engineer stopped without changing anything. Send it a message in the
          conversation to pick up where it left off.
        </p>
      </div>

      <div class="w-full max-w-3xl space-y-3" aria-hidden="true">
        <div class={[
          "h-4 w-1/3 rounded bg-slate-200 dark:bg-slate-800",
          @running && "motion-safe:animate-pulse"
        ]} />
        <div
          :for={width <- ["w-full", "w-11/12", "w-4/5"]}
          class={["h-2.5 rounded bg-slate-100 dark:bg-slate-800/60", width]}
        />
      </div>
    </div>
    """
  end

  # The diff is read and highlighted once the page is live, so the first page
  # holds its place in the same frame the diff will fill.
  defp diff_loading(assigns) do
    ~H"""
    <div
      id="engineer-diff-loading"
      data-qa="engineer_diff_loading"
      aria-busy="true"
      class="h-full space-y-3 p-6"
    >
      <div class="h-4 w-1/3 rounded bg-slate-200 dark:bg-slate-800 motion-safe:animate-pulse" />
      <div
        :for={width <- ["w-full", "w-11/12", "w-4/5"]}
        class={["h-2.5 rounded bg-slate-100 dark:bg-slate-800/60 motion-safe:animate-pulse", width]}
      />
    </div>
    """
  end

  # What the reader is looking at is one view of the branch; whether there is any
  # work at all is the branch's own question, so a view that happens to be empty
  # is still a view, with the toolbar that gets them back out of it.
  defp load_diff(socket) do
    %{current_scope: scope, task: task, filter: filter, highlighted: highlighted} = socket.assigns
    files = diff(scope, task, filter, Enum.concat(Map.values(highlighted)))
    highlighted = keep(highlighted, scope, task, filter, files)

    socket
    |> fold_away_read_files(files)
    |> assign(:files, files)
    |> assign(:comments, Pipeline.list_diff_comments(scope, task))
    |> assign(:work?, highlighted.branch != [])
    |> assign(:highlighted, highlighted)
    |> assign(:loading?, false)
    |> sync_pane()
  end

  # The browser redraws everything under whatever a patch touches, so the pane is
  # drawn whole only when its frame moves and any other change goes to its part.
  defp sync_pane(%{assigns: %{work?: true, loading?: false, sent: %{} = sent}} = socket) do
    state = pane_state(socket.assigns)
    pane = calculate_diff_pane(state)
    socket = if pane.frame == sent.frame, do: socket, else: assign(socket, :drawn, state)

    send_parts(pane, sent)

    assign(socket, :sent, pane)
  end

  defp sync_pane(%{assigns: %{work?: true, loading?: false}} = socket) do
    state = pane_state(socket.assigns)

    socket |> assign(:drawn, state) |> assign(:sent, calculate_diff_pane(state))
  end

  defp sync_pane(socket), do: assign(socket, :sent, nil)

  defp pane_state(assigns) do
    %{
      files: assigns.files,
      filter: assigns.filter,
      query: assigns.query,
      show_file_tree: assigns.show_files,
      collapsed: assigns.collapsed,
      expanded_gaps: assigns.expanded_gaps,
      selected_file: assigns.selected_file,
      scroll_to: assigns.focus_file,
      target: assigns.myself,
      empty_message: empty_message(assigns.filter),
      comments: assigns.comments,
      draft: assigns.draft,
      engineer_running?: Run.running?(assigns.run)
    }
  end

  # Only to parts already on the page: a part the frame is adding is drawn by it.
  defp send_parts(pane, sent) do
    if pane.toolbar != sent.toolbar, do: send_update(DiffToolbar, Map.put(pane.toolbar, :id, "diff-toolbar"))

    if pane.tree && sent.tree && pane.tree != sent.tree,
      do: send_update(DiffFileTree, Map.put(pane.tree, :id, "diff-file-tree"))

    sent_sections = Map.new(sent.sections)

    for {id, section} <- pane.sections, Map.has_key?(sent_sections, id), sent_sections[id] != section do
      send_update(DiffFile, Map.put(section, :id, id))
    end
  end

  defp load_status(socket) do
    %{task: task} = socket.assigns
    present? = Task.worktree_present?(task)

    dirty? = present? and Git.worktree_dirty?(task.worktree_path)
    unpushed? = present? and Git.branch_unpushed?(task.worktree_path)
    ci = Pipeline.get_ci_status(socket.assigns.run)

    socket
    |> assign(:dirty?, dirty?)
    |> assign(:unpushed?, unpushed?)
    |> assign(:ci, ci)
    |> assign(:show_run_ci?, show_run_ci?(ci, dirty?))
    |> assign(:changed_since_review?, task.stage in [:review, :qa, :demo] and Pipeline.changed_since_review?(task))
  end

  # A commit waiting on CI is sent on by running it, not by pushing: CI pushes it
  # once it passes. Anything uncommitted is committed first, which runs CI anyway.
  defp show_run_ci?(%{state: state}, false) when state in [:pending, :failed], do: true
  defp show_run_ci?(_ci, _dirty?), do: false

  defp ci_passed?(nil), do: true
  defp ci_passed?(%{state: state}), do: state == :passed

  defp ci_label(%{state: :running}), do: "CI running"
  defp ci_label(%{state: :passed}), do: "CI passed"
  defp ci_label(%{state: :failed, failures: failures}) when failures > 0, do: "CI failed · #{failures} of 3"
  defp ci_label(%{state: :failed}), do: "CI failed"
  defp ci_label(%{state: :pending}), do: "CI not run"

  defp ci_title(%{os_process: %{command: command}}), do: command
  defp ci_title(_never_run), do: nil

  defp ci_tone(:running), do: "bg-blue-500/10 text-blue-700 dark:text-blue-300"
  defp ci_tone(:passed), do: "bg-green-500/10 text-green-700 dark:text-green-300"
  defp ci_tone(:failed), do: "bg-red-500/10 text-red-700 dark:text-red-300"
  defp ci_tone(:pending), do: "bg-slate-500/10 text-slate-600 dark:text-slate-300"

  defp ci_icon(:running), do: "pi-circle-notch"
  defp ci_icon(:passed), do: "pi-check-circle"
  defp ci_icon(:failed), do: "pi-x-circle"
  defp ci_icon(:pending), do: "pi-clock"

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

  # Both views are kept so either's next load reuses whatever has not moved, which
  # also makes the branch read the uncommitted view needs for `work?` cheap.
  defp keep(highlighted, _scope, _task, :branch, files), do: Map.put(highlighted, :branch, files)

  defp keep(highlighted, scope, task, :uncommitted, files) do
    branch = diff(scope, task, :branch, files ++ Enum.concat(Map.values(highlighted)))

    Map.merge(highlighted, %{uncommitted: files, branch: branch})
  end

  defp diff(scope, task, filter, previous_files) do
    case Git.load_diff(scope, task, filter, previous_files) do
      {:ok, files} -> files
      {:error, :no_worktree} -> []
    end
  end

  defp commit_label(true, true), do: "Committing…"
  defp commit_label(false, true), do: "Pushing…"
  defp commit_label(true, false), do: "Commit"
  defp commit_label(false, false), do: "Push"

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

  defp message_for(:stage_running), do: "Something is still running on this task."
  defp message_for(:uncommitted_changes), do: "Commit the engineer's work before sending it to review."
  defp message_for(:unpushed_changes), do: "Push the engineer's commits before sending them to review."
  defp message_for(:nothing_to_commit), do: "There is nothing left to commit."
  defp message_for(:ci_not_passed), do: "CI has to pass on the latest commit before this goes to review."
  defp message_for(:nothing_new_to_review), do: "Review has already seen this commit."
  defp message_for(:chat_unavailable), do: "The engineer has no conversation to send these to yet."
  defp message_for(:nothing_to_send), do: "There are no comments to send."
  defp message_for(reason) when is_binary(reason), do: reason
  defp message_for(reason), do: "Could not finish that: #{inspect(reason)}"
end
