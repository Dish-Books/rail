defmodule RailWeb.Live.FinalizeStage do
  @moduledoc """
  Finalize: the pull request Review finished, Mark ready for a teammate, then Merge for a tech lead, beside the
  Review conversation. Everyone else is told which tech leads to ask.
  """
  use RailWeb, :live_component

  alias Rail.Git
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Scope
  alias Rail.Users

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:error, fn -> nil end)
      |> assign_new(:merging, fn -> false end)
      |> load()

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="finalize-stage" data-qa="finalize-stage" class="contents">
      <.task_layout
        task={@task}
        run={@run}
        stage_run={@stage_run}
        line={@line}
        title={@task.issue.title}
      >
        <:breadcrumb :if={@breadcrumb != []}>{render_slot(@breadcrumb)}</:breadcrumb>
        <:tabs>{render_slot(@tabs)}</:tabs>
        <:actions>{render_slot(@actions)}</:actions>

        <div id="finalize-pane" data-state={@state} class="max-w-[720px] space-y-4">
          <div
            id="finalize-pr"
            class="rounded-xl border border-slate-200 dark:border-slate-700 bg-slate-50 dark:bg-slate-800/40"
          >
            <div class="flex items-start gap-3 px-5 py-4 border-b border-slate-200 dark:border-slate-700">
              <span class="mt-0.5">
                <.icon
                  name={if @state == :merged, do: "pi-git-merge-fill", else: "pi-git-pull-request"}
                  class={[
                    "size-5",
                    @state == :merged && "text-emerald-600 dark:text-emerald-400",
                    @state != :merged && "text-slate-500 dark:text-slate-300"
                  ]}
                />
              </span>
              <div class="min-w-0 flex-1">
                <div class="flex items-center gap-2 min-w-0">
                  <span class="text-[15px] font-semibold text-slate-900 dark:text-slate-100 truncate">
                    {@task.issue.identifier} {@task.issue.title}
                  </span>
                  <span
                    id="finalize-pr-state"
                    class={[
                      "shrink-0 rounded-full px-2 py-0.5 text-[11px] font-semibold",
                      @state == :merged &&
                        "bg-emerald-100 dark:bg-emerald-950 text-emerald-800 dark:text-emerald-300",
                      @state != :merged &&
                        "bg-slate-200 dark:bg-slate-700 text-slate-700 dark:text-slate-200"
                    ]}
                  >
                    {if @state == :merged, do: "Merged", else: "Open"}
                  </span>
                </div>
                <div class="mt-0.5 flex items-center gap-1.5 min-w-0 text-xs text-slate-500 dark:text-slate-400">
                  <span class="font-mono shrink-0 text-blue-600 dark:text-blue-400">#{@task.pr_number}</span>
                  <span class="shrink-0">into</span>
                  <span class="font-mono shrink-0 text-slate-700 dark:text-slate-300">
                    {@task.project.default_branch}
                  </span>
                  <span class="shrink-0">from</span>
                  <span
                    class="font-mono truncate text-slate-700 dark:text-slate-300"
                    title={@task.worktree_name}
                  >
                    {@task.worktree_name}
                  </span>
                </div>
              </div>
              <a
                :if={@task.pr_url}
                href={@task.pr_url}
                target="_blank"
                rel="noopener noreferrer"
                id="finalize-pr-link"
                class="shrink-0 inline-flex items-center gap-1 text-xs font-semibold text-blue-600 dark:text-blue-400 hover:underline"
              >
                GitHub<.icon name="pi-arrow-up-right" class="size-3" />
              </a>
            </div>
            <dl class="grid grid-cols-[88px_1fr] gap-y-2 px-5 py-4 text-[13px]">
              <dt class="text-slate-500 dark:text-slate-400">Commits</dt>
              <dd id="finalize-commits" class="text-slate-800 dark:text-slate-200">
                {length(@history.commits)}
                <span class="font-mono text-[12px] text-emerald-600 dark:text-emerald-400">
                  +{@history.additions}
                </span>
                <span class="font-mono text-[12px] text-red-600 dark:text-red-400">
                  &minus;{@history.deletions}
                </span>
              </dd>
              <dt class="text-slate-500 dark:text-slate-400">Review</dt>
              <dd id="finalize-review" class="text-slate-800 dark:text-slate-200">{@review}</dd>
            </dl>
          </div>

          <div
            :if={@state == :refused}
            id="finalize-merge-error"
            role="alert"
            class="flex gap-2.5 rounded-xl border border-red-200 dark:border-red-900 bg-red-50 dark:bg-red-950 p-3 text-xs text-red-700 dark:text-red-300"
          >
            <.icon
              name="pi-warning-circle"
              class="size-4 shrink-0 mt-px text-red-500 dark:text-red-400"
            />
            <div class="min-w-0 space-y-1">
              <p class="font-semibold text-red-800 dark:text-red-200">
                GitHub refused the merge at
                <.local_time id="finalize-merge-error-at" at={@task.merge_error_at} />
              </p>
              <p class="font-mono text-[11.5px] wrap-anywhere">{@task.merge_error}</p>
            </div>
          </div>

          <div :if={@state == :not_ready} class="flex items-center gap-3">
            <.button
              id="finalize-mark-ready"
              variant="primary"
              phx-click="mark_ready"
              phx-target={@myself}
              phx-disable-with="Marking…"
            >
              <.icon name="pi-flag" class="size-4" />Mark ready
            </.button>
          </div>

          <p
            :if={@state != :not_ready and @task.marked_ready_at != nil}
            id="finalize-marked"
            class="flex items-center gap-2 text-[13px] text-slate-600 dark:text-slate-300"
          >
            <.icon name="pi-seal-check" class="size-4 shrink-0 text-slate-400" />
            <span>
              Marked ready by {name(@task.marked_ready_by)} at
              <.local_time id="finalize-marked-at" at={@task.marked_ready_at} />
            </span>
          </p>

          <div
            :if={@state in [:ready, :merging, :refused] and @tech_lead}
            class="flex items-center gap-3"
          >
            <.button
              id="finalize-merge"
              variant="primary"
              phx-click="merge"
              phx-target={@myself}
              disabled={@state == :merging or @merging}
            >
              <.icon
                name={if @state == :merging or @merging, do: "pi-circle-notch", else: "pi-git-merge"}
                class={["size-4", (@state == :merging or @merging) && "motion-safe:animate-spin"]}
              />
              {if @state == :merging or @merging, do: "Merging…", else: "Merge"}
            </.button>
            <span class="text-xs text-slate-500 dark:text-slate-400">
              Squash into <span class="font-mono">{@task.project.default_branch}</span>
            </span>
          </div>

          <p
            :if={@state in [:ready, :merging, :refused] and not @tech_lead}
            id="finalize-waiting"
            class="flex items-center gap-2 text-[13px] text-slate-600 dark:text-slate-300"
          >
            <.icon name="pi-hourglass-medium" class="size-4 shrink-0 text-slate-400" />
            {waiting(@tech_leads)}
          </p>

          <p
            :if={@state == :merged}
            id="finalize-merged"
            class="flex flex-wrap items-center gap-x-1 gap-y-0.5 text-[13px] text-slate-800 dark:text-slate-200"
          >
            <.icon
              name="pi-git-merge-fill"
              class="size-4 mr-1 shrink-0 text-emerald-600 dark:text-emerald-400"
            /> Squash merged into
            <span class="font-mono text-[12px]">{@task.project.default_branch}</span>
            by {name(@task.merged_by)} at <.local_time id="finalize-merged-at" at={@task.merged_at} />
            as
            <span class="font-mono text-[12px] text-blue-600 dark:text-blue-400">
              {String.slice(@task.merge_sha || "", 0, 7)}
            </span>
          </p>

          <p :if={@error} id="finalize-error" class="text-xs text-red-600 dark:text-red-500">
            {@error}
          </p>
        </div>

        <:sidebar>{render_slot(@sidebar)}</:sidebar>
      </.task_layout>
    </div>
    """
  end

  @impl true
  def handle_event("mark_ready", _params, socket) do
    case Pipeline.mark_ready(socket.assigns.current_scope, socket.assigns.task) do
      {:ok, _task} ->
        send(self(), :task_changed)
        {:noreply, assign(socket, :error, nil)}

      {:error, reason} ->
        {:noreply, assign(socket, :error, message_for(reason))}
    end
  end

  def handle_event("merge", _params, %{assigns: %{merging: true}} = socket), do: {:noreply, socket}

  def handle_event("merge", _params, socket) do
    %{current_scope: scope, task: task} = socket.assigns

    socket =
      socket
      |> assign(:merging, true)
      |> assign(:error, nil)
      |> start_async(:merge, fn ->
        # Unlinked, so leaving the page does not cut a merge off between GitHub's answer and recording it.
        Rail.TaskSupervisor
        |> Elixir.Task.Supervisor.async_nolink(fn -> Pipeline.merge_task(scope, task) end)
        |> Elixir.Task.await(:infinity)
      end)

    {:noreply, socket}
  end

  # GitHub's refusal is the task's own, so the pane shows it from the row like every other tab does.
  @impl true
  def handle_async(:merge, {:ok, result}, socket) do
    send(self(), :task_changed)

    error =
      case result do
        {:ok, _merged} -> nil
        {:error, {:merge_refused, _message}} -> nil
        {:error, reason} -> message_for(reason)
      end

    socket = socket |> assign(:merging, false) |> assign(:error, error)
    {:noreply, socket}
  end

  def handle_async(:merge, {:exit, _reason}, socket) do
    send(self(), :task_changed)
    socket = socket |> assign(:merging, false) |> assign(:error, "The merge did not finish. Try again.")
    {:noreply, socket}
  end

  defp load(socket) do
    %{task: task, current_scope: scope} = socket.assigns
    passes = Pipeline.read_review(task)
    findings = Pipeline.list_findings(task)
    state = Task.finalize_state(task)
    tech_lead = Scope.tech_lead?(scope)

    socket
    |> assign(:state, state)
    |> assign(:tech_lead, tech_lead)
    |> assign(:history, Git.load_branch_history(task, for(%{head: head} <- passes, is_binary(head), do: head)))
    |> assign(:review, review(passes, findings))
    |> assign(
      :tech_leads,
      if(tech_lead or state in [:not_ready, :merged], do: [], else: Users.list_tech_leads(task.project_id))
    )
  end

  defp review(passes, findings) do
    fixed = Enum.count(findings, &(&1.status == :fixed))
    dismissed = Enum.count(findings, &(Finding.state(&1) in [:dismissed, :suppressed]))
    rounds = if length(passes) == 1, do: "1 round", else: "#{length(passes)} rounds"

    "Finished in #{rounds} · #{fixed} fixed · #{dismissed} not fixing"
  end

  defp waiting([]), do: "Waiting for a tech lead"

  defp waiting(leads) do
    names = Enum.map(leads, &name/1)
    "Waiting for a tech lead: " <> Enum.join(Enum.drop(names, -1), ", ") <> or_last(names)
  end

  defp or_last([only]), do: only
  defp or_last(names), do: " or " <> List.last(names)

  # A user deleted since, or a GitHub merger with no Rail account, leaves the record with nobody's name on it.
  defp name(%{name: name, login: login}), do: if(name in [nil, ""], do: login, else: name)
  defp name(nil), do: "someone"

  defp message_for(:not_authorized), do: "Only a tech lead can merge a task."
  defp message_for(:not_ready), do: "Mark the task ready before merging it."
  defp message_for(:merging), do: "A merge is already under way."
  defp message_for(:merged), do: "This task is already merged."
  defp message_for(:no_pull_request), do: "This task has no pull request to merge."
  defp message_for({:invalid_stage, stage}), do: "This task is at #{Task.stage_label(stage)}, not Finalize."
end
