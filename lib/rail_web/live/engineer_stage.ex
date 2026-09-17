defmodule RailWeb.Live.EngineerStage do
  @moduledoc """
  The change the engineer made, and the two decisions a human takes on it.

  The diff is read off the worktree every time, because it is the worktree that
  moved and no row records that. Two views of it: everything on the branch, which
  is what review means, and only what is uncommitted, which is what "what has it
  changed since I last looked" means. Marking a file read is per person and
  pinned to the file as it was read, so a file the engineer touches again comes
  back unread.
  """
  use RailWeb, :live_component

  alias Rail.Git
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task

  @impl true
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
      |> assign_new(:focus_file, fn -> nil end)
      |> assign_new(:expanded_gaps, fn -> %{} end)

    socket = if socket.assigns.focus_file, do: assign(socket, :selected_file, socket.assigns.focus_file), else: socket

    {:ok, load(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="engineer-stage" data-qa="engineer-stage" class="contents">
      <.task_layout task={@task} run={@run} title={@task.issue.title} flush={@work?}>
        <:tabs>{render_slot(@tabs)}</:tabs>
        <:actions>
          {render_slot(@actions)}

          <button
            :if={@approvable and (@dirty? or @unpushed? or @committing)}
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
            :if={@approvable and @work?}
            type="button"
            id="send-to-review"
            data-qa="send_to_review"
            phx-click="send_to_review"
            phx-target={@myself}
            disabled={@committing}
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

        <.work_pending :if={not @work?} running={Run.running?(@run)} />

        <div :if={@work?} id="engineer-diff" data-qa="engineer_diff" class="h-full">
          <.diff_pane
            files={@files}
            filter={@filter}
            query={@query}
            show_file_tree={@show_files}
            collapsed={@collapsed}
            expanded_gaps={@expanded_gaps}
            selected_file={@selected_file}
            scroll_to={@focus_file}
            target={@myself}
            empty_message={empty_message(@filter)}
          />
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

    {:noreply, load(socket)}
  end

  def handle_event("filter_diff_files", %{"query" => query}, socket) do
    {:noreply, assign(socket, :query, query)}
  end

  def handle_event("toggle_file_list", _params, socket) do
    {:noreply, assign(socket, :show_files, not socket.assigns.show_files)}
  end

  def handle_event("toggle_collapsed", %{"path" => path}, socket) do
    {:noreply, assign(socket, :collapsed, toggle(socket.assigns.collapsed, path, path not in socket.assigns.collapsed))}
  end

  def handle_event("select_diff_file", %{"path" => path}, socket) do
    {:noreply, assign(socket, :selected_file, path)}
  end

  # Reading a file is also done with it, so it folds away; the caret is there to
  # open it again.
  def handle_event("toggle_viewed", %{"path" => path, "digest" => digest}, socket) do
    read_already? = Enum.any?(socket.assigns.files, &(&1.path == path and &1.viewed?))

    _marked =
      Git.set_file_viewed(socket.assigns.current_scope, socket.assigns.task, path, digest, not read_already?)

    socket = socket |> assign(:collapsed, toggle(socket.assigns.collapsed, path, not read_already?)) |> load()

    {:noreply, socket}
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

    {:noreply, assign(socket, :expanded_gaps, Map.put(socket.assigns.expanded_gaps, key, lines))}
  end

  # A push runs the repository's own pre-push hooks, which can take minutes, so it
  # goes off the LiveView process and the button says it is in flight. A second
  # click while it is would only race the first.
  def handle_event("commit", _params, %{assigns: %{committing: true}} = socket), do: {:noreply, socket}

  def handle_event("commit", _params, socket) do
    %{current_scope: scope, task: task} = socket.assigns

    socket =
      socket
      |> assign(:committing, true)
      |> assign(:error, nil)
      |> start_async(:commit, fn -> Pipeline.commit_engineer_work(scope, task) end)

    {:noreply, socket}
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
  def handle_async(:commit, {:ok, :ok}, socket) do
    {:ok, _cleared} = Pipeline.update_run(socket.assigns.run, %{error: nil})
    send(self(), :task_changed)

    socket = socket |> assign(:committing, false) |> assign(:error, nil) |> load()

    {:noreply, socket}
  end

  def handle_async(:commit, {:ok, {:error, reason}}, socket) do
    socket = socket |> assign(:committing, false) |> assign(:error, message_for(reason)) |> load()

    {:noreply, socket}
  end

  def handle_async(:commit, {:exit, reason}, socket) do
    socket = socket |> assign(:committing, false) |> assign(:error, message_for(reason)) |> load()

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

  # What the reader is looking at is one view of the branch; whether there is any
  # work at all is the branch's own question, so a view that happens to be empty
  # is still a view, with the toolbar that gets them back out of it.
  defp load(socket) do
    %{current_scope: scope, task: task, filter: filter} = socket.assigns
    files = diff(scope, task, filter)
    present? = Task.worktree_present?(task)

    socket
    |> fold_away_read_files(files)
    |> assign(:files, files)
    |> assign(:work?, work?(scope, task, filter, files))
    |> assign(:dirty?, present? and Git.worktree_dirty?(task.worktree_path))
    |> assign(:unpushed?, present? and Git.branch_unpushed?(task.worktree_path))
  end

  # A file already read is folded away the first time it is seen that way, and
  # only then: a reader who opens one again has it stay open. The engineer
  # touching it makes it unread, which lets it fold again on the next pass.
  defp fold_away_read_files(socket, files) do
    {read, unread} = Enum.split_with(files, & &1.viewed?)
    fresh = Enum.reject(read, &MapSet.member?(socket.assigns.auto_collapsed, &1.path))

    socket
    |> assign(:collapsed, Enum.uniq(Enum.map(fresh, & &1.path) ++ socket.assigns.collapsed))
    |> assign(:auto_collapsed, forget(socket.assigns.auto_collapsed, read, unread))
  end

  defp forget(auto_collapsed, read, unread) do
    auto_collapsed
    |> MapSet.union(MapSet.new(read, & &1.path))
    |> MapSet.difference(MapSet.new(unread, & &1.path))
  end

  defp work?(_scope, _task, :branch, files), do: files != []
  defp work?(scope, task, :uncommitted, _files), do: diff(scope, task, :branch) != []

  defp diff(scope, task, filter) do
    case Git.load_diff(scope, task, filter) do
      {:ok, files} -> files
      {:error, :no_worktree} -> []
    end
  end

  defp commit_label(true, true), do: "Committing…"
  defp commit_label(false, true), do: "Pushing…"
  defp commit_label(true, false), do: "Commit"
  defp commit_label(false, false), do: "Push"

  defp toggle(paths, path, true), do: Enum.uniq([path | paths])
  defp toggle(paths, path, false), do: List.delete(paths, path)

  defp empty_message(:uncommitted), do: "Everything in the worktree is committed."
  defp empty_message(:branch), do: "Nothing has been changed on this branch yet."

  defp message_for(:stage_running), do: "Something is still running on this task."
  defp message_for(:uncommitted_changes), do: "Commit the engineer's work before sending it to review."
  defp message_for(:unpushed_changes), do: "Push the engineer's commits before sending them to review."
  defp message_for(:nothing_to_commit), do: "There is nothing left to commit."
  defp message_for(reason) when is_binary(reason), do: reason
  defp message_for(reason), do: "Could not finish that: #{inspect(reason)}"
end
