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
      |> assign_new(:filter, fn -> :branch end)
      |> assign_new(:selected_file, fn -> nil end)
      |> assign_new(:expanded_gaps, fn -> %{} end)

    {:ok, load(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="engineer-stage" data-qa="engineer-stage" class="contents">
      <.task_layout task={@task} run={@run} title={@task.issue.title}>
        <:tabs>{render_slot(@tabs)}</:tabs>
        <:actions>
          {render_slot(@actions)}

          <button
            :if={@approvable and @dirty?}
            type="button"
            id="commit-work"
            data-qa="commit_work"
            phx-click="commit"
            phx-target={@myself}
            disabled={Run.running?(@run)}
            class="px-4 py-2 rounded-lg border border-slate-300 dark:border-slate-600 text-sm font-semibold text-slate-900 dark:text-slate-100 hover:bg-slate-50 dark:hover:bg-slate-800 cursor-pointer disabled:opacity-50"
          >
            Commit
          </button>

          <button
            :if={@approvable and @files != []}
            type="button"
            id="send-to-review"
            data-qa="send_to_review"
            phx-click="send_to_review"
            phx-target={@myself}
            class="px-4 py-2 rounded-lg text-sm font-semibold bg-blue-600 dark:bg-blue-500 text-white hover:opacity-90 cursor-pointer shadow-xs"
          >
            Send to review
          </button>
        </:actions>

        <:alerts :if={@error}>
          <p
            id="engineer-error"
            data-qa="engineer_error"
            class="text-xs text-red-600 dark:text-red-500"
          >
            {@error}
          </p>
        </:alerts>

        <.work_pending :if={@files == []} running={Run.running?(@run)} />

        <div :if={@files != []} id="engineer-diff" data-qa="engineer_diff" class="space-y-3">
          <div
            id="diff-filter"
            data-qa="diff_filter"
            class="inline-flex rounded-lg border border-slate-200 dark:border-slate-700 p-0.5 bg-white dark:bg-slate-900"
          >
            <button
              :for={{filter, label} <- [branch: "All changes", uncommitted: "Uncommitted"]}
              type="button"
              id={"diff-filter-#{filter}"}
              data-qa="diff_filter_option"
              phx-click="select_diff_filter"
              phx-target={@myself}
              phx-value-filter={filter}
              class={[
                "px-3 py-1.5 rounded-md text-xs font-semibold cursor-pointer",
                @filter == filter &&
                  "bg-slate-100 dark:bg-slate-700 text-slate-900 dark:text-slate-100",
                @filter != filter &&
                  "text-slate-500 dark:text-slate-400 hover:text-slate-900 dark:hover:text-slate-100"
              ]}
            >
              {label}
            </button>
          </div>

          <.diff_pane
            files={@files}
            expanded_gaps={@expanded_gaps}
            selected_file={@selected_file}
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
      |> assign(:selected_file, nil)

    {:noreply, load(socket)}
  end

  def handle_event("select_diff_file", %{"path" => path}, socket) do
    {:noreply, assign(socket, :selected_file, path)}
  end

  def handle_event("toggle_viewed", %{"path" => path, "digest" => digest}, socket) do
    read_already? = Enum.any?(socket.assigns.files, &(&1.path == path and &1.viewed?))

    _marked =
      Git.set_file_viewed(socket.assigns.current_scope, socket.assigns.task, path, digest, not read_already?)

    {:noreply, load(socket)}
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

  def handle_event("commit", _params, socket) do
    case Pipeline.commit_engineer_work(socket.assigns.current_scope, socket.assigns.task) do
      {:ok, _sha} ->
        socket = socket |> assign(:error, nil) |> load()
        {:noreply, socket}

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

  defp load(socket) do
    %{current_scope: scope, task: task, filter: filter} = socket.assigns

    files =
      case Git.load_diff(scope, task, filter) do
        {:ok, files} -> files
        {:error, :no_worktree} -> []
      end

    socket
    |> assign(:files, files)
    |> assign(:dirty?, Task.worktree_present?(task) and Git.worktree_dirty?(task.worktree_path))
  end

  defp empty_message(:uncommitted), do: "Everything in the worktree is committed."
  defp empty_message(:branch), do: "Nothing has been changed on this branch yet."

  defp message_for(:stage_running), do: "Something is still running on this task."
  defp message_for(:uncommitted_changes), do: "Commit the engineer's work before sending it to review."
  defp message_for(:nothing_to_commit), do: "There is nothing left to commit."
  defp message_for(reason) when is_binary(reason), do: reason
  defp message_for(reason), do: "Could not finish that: #{inspect(reason)}"
end
