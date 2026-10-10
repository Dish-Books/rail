defmodule RailWeb.Live.EngineerStage do
  @moduledoc """
  The change the engineer made, where CI stands on it, and the two decisions a
  human takes on it.

  The diff itself, its views and the comments on it are `RailWeb.Live.DiffView`'s.
  Once the task has left Engineer the branch is the Review lead's, so comments
  written here go to its conversation, the engineer's being closed.
  """
  use RailWeb, :live_component

  alias Rail.Git
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias RailWeb.Live.DiffView

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:error, fn -> nil end)
      |> assign_new(:pushing, fn -> false end)
      |> load_status()

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
        flush={@work?}
      >
        <:breadcrumb :if={@breadcrumb != []}>{render_slot(@breadcrumb)}</:breadcrumb>
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
            :if={@show_run_ci? and @at_engineer and not Run.running?(@run)}
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
            :if={(@unpushed? or @pushing) and @at_engineer and not @show_run_ci?}
            type="button"
            id="push-work"
            data-qa="push_work"
            phx-click="push"
            phx-target={@myself}
            disabled={@pushing or Run.running?(@run)}
            aria-busy={to_string(@pushing)}
            class="inline-flex items-center gap-2 px-4 py-2 rounded-lg border border-slate-300 dark:border-slate-600 text-sm font-semibold text-slate-900 dark:text-slate-100 hover:bg-slate-50 dark:hover:bg-slate-800 cursor-pointer disabled:opacity-50 disabled:cursor-not-allowed"
          >
            <.icon :if={@pushing} name="pi-circle-notch" class="size-4 motion-safe:animate-spin" />
            {if @pushing, do: "Pushing…", else: "Push"}
          </button>

          <button
            :if={@approvable and @work? and not Run.running?(@run)}
            type="button"
            id="send-to-review"
            data-qa="send_to_review"
            phx-click="send_to_review"
            phx-target={@myself}
            disabled={@pushing or not ci_passed?(@ci)}
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

        <.work_pending :if={not @work?} running={Run.running?(@run)} />

        <div :if={@work?} id="engineer-diff" data-qa="engineer_diff" class="h-full">
          <.live_component
            module={DiffView}
            id="diff-view"
            task={@task}
            run={if @at_engineer or is_nil(@stage_run), do: @run, else: @stage_run}
            agent={if @at_engineer or is_nil(@stage_run), do: "Engineer", else: "Review lead"}
            current_scope={@current_scope}
            focus_file={@focus_file}
          />
        </div>

        <:sidebar>{render_slot(@sidebar)}</:sidebar>
      </.task_layout>
    </div>
    """
  end

  @impl true
  # A push runs the repository's own pre-push hooks, which can take minutes, so it
  # goes off the LiveView process and the button says it is in flight. A second
  # click while it is would only race the first.
  def handle_event("push", _params, %{assigns: %{pushing: true}} = socket), do: {:noreply, socket}

  def handle_event("push", _params, socket) do
    %{current_scope: scope, run: run} = socket.assigns

    socket =
      socket
      |> assign(:pushing, true)
      |> assign(:error, nil)
      |> start_async(:push, fn ->
        # Unlinked, so leaving the page does not cut a hand-over off between its go-ahead
        # and the push, CI or review that settles it.
        Rail.TaskSupervisor
        |> Elixir.Task.Supervisor.async_nolink(fn -> Pipeline.hand_over_work(scope, run) end)
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

  # The action clears the run's own error, since it can finish after the page is
  # gone. Either way the status is read again: what is left unpushed is what the button offers next.
  @impl true
  def handle_async(:push, {:ok, {:ok, _run}}, socket) do
    send(self(), :task_changed)

    socket = socket |> assign(:pushing, false) |> assign(:error, nil) |> load_status()

    {:noreply, socket}
  end

  def handle_async(:push, {:ok, {:error, reason}}, socket) do
    socket = socket |> assign(:pushing, false) |> assign(:error, message_for(reason)) |> load_status()

    {:noreply, socket}
  end

  def handle_async(:push, {:exit, reason}, socket) do
    socket = socket |> assign(:pushing, false) |> assign(:error, message_for(reason)) |> load_status()

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

  defp load_status(socket) do
    %{task: task} = socket.assigns
    unpushed? = Task.worktree_present?(task) and Git.branch_unpushed?(task.worktree_path)
    ci = Pipeline.get_ci_status(socket.assigns.run)

    socket
    |> assign(:unpushed?, unpushed?)
    |> assign(:work?, Git.branch_changed?(task))
    |> assign(:ci, ci)
    |> assign(:show_run_ci?, show_run_ci?(ci))
    # Past Engineer the branch is Review's, whose lead hands its fix rounds on.
    |> assign(:at_engineer, task.stage == :engineer)
  end

  # A commit waiting on CI is sent on by running it, not by pushing: CI pushes it once it passes.
  defp show_run_ci?(%{state: state}) when state in [:pending, :failed], do: true
  defp show_run_ci?(_ci), do: false

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

  defp message_for(:stage_running), do: "Something is still running on this task."
  defp message_for(:unpushed_changes), do: "Push the engineer's commits before sending them to review."
  defp message_for(:nothing_to_send), do: "There is nothing left to push."
  defp message_for(:ci_not_passed), do: "CI has to pass on the latest commit before this goes to review."
  defp message_for(reason) when is_binary(reason), do: reason
  defp message_for(reason), do: "Could not finish that: #{inspect(reason)}"
end
