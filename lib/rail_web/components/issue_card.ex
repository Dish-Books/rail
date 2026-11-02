defmodule RailWeb.Components.IssueCard do
  @moduledoc """
  One issue as a single row of the issues list, opening the issue's page. A sub-issue is indented, a dimmed parent is
  context. An `actionable` row opens its task, a flagged one at `waiting_path/1`, and offers Start on an issue with none.
  """
  use RailWeb, :html

  import RailWeb.Utils.StageLabel, only: [waiting_path: 1]

  alias Phoenix.LiveView.JS
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Workflows.Schemas.Workflow
  alias RailWeb.Components.StatusPicker

  attr :issue, :map, required: true
  attr :current_scope, :any, required: true
  attr :task, :map, default: nil
  attr :run, :any, default: nil
  # A parent can show more than once on a page, so each row brings its own key; it defaults to the issue's id.
  attr :row_key, :string, default: nil
  attr :nested, :boolean, default: false
  attr :dimmed, :boolean, default: false
  attr :open_blockers, :list, default: []
  attr :actionable, :boolean, default: false

  def issue_card(%{issue: issue, task: task, actionable: actionable} = assigns) do
    {done, total} = Issue.calculate_sub_issue_count(issue)
    blocker_names = Enum.map_join(assigns.open_blockers, ", ", & &1.issue.identifier)
    run = assigns.run && %{assigns.run | task: task}
    needs = actionable and run != nil and Run.needs_attention?(run)
    finished = Issue.finished_state?(issue.state)
    # A reopened issue's merged task is history, so with no task of its own the row starts one.
    started = Enum.find([issue.task, finished && issue.merged_task], &match?(%Task{}, &1))

    assigns =
      assigns
      |> assign(:key, assigns.row_key || issue.id)
      |> assign(:path, row_path(issue, actionable, needs && run, started))
      |> assign(:flag, row_flag(actionable, needs, run))
      |> assign(:flagged, needs)
      |> assign(:style, if(actionable and task != nil, do: run_state_style(run, task)))
      |> assign(:show_start, actionable and not assigns.dimmed and is_nil(issue.task) and not finished)
      |> assign(:sub_issues_done, done)
      |> assign(:sub_issues, total)
      |> assign(:blocked_title, "Blocked by #{blocker_names}")

    ~H"""
    <div
      id={"issue-card-#{@key}"}
      data-qa={"issue-row issue-card-#{@issue.id}"}
      data-context={@dimmed && "true"}
      data-flagged={@flagged && "true"}
      class={[
        "group flex items-center gap-3 h-11 cursor-pointer hover:bg-slate-50 dark:hover:bg-slate-800/60 transition-colors",
        if(@actionable, do: "pl-3.5 pr-4 border-l-2", else: "px-4"),
        @flag,
        @dimmed && "opacity-60"
      ]}
      phx-click={JS.navigate(@path)}
    >
      <span :if={@nested} class="relative w-5 shrink-0 self-stretch" aria-hidden="true">
        <span class="absolute left-1.5 top-0 bottom-1/2 w-3 border-l border-b border-slate-300 dark:border-slate-600 rounded-bl-md"></span>
      </span>

      <span
        data-qa="issue-priority-badge"
        title={priority_label(@issue.priority)}
        class="flex items-center justify-center w-4 shrink-0"
      >
        <.priority_icon priority={@issue.priority} />
        <span class="sr-only">{priority_label(@issue.priority)}</span>
      </span>

      <span
        data-qa="issue-identifier"
        class="w-20 shrink-0 text-xs font-mono text-slate-500 dark:text-slate-400 truncate"
      >
        {@issue.identifier}
      </span>

      <span
        :if={@dimmed}
        data-qa="issue-status-badge"
        title={Issue.calculate_status_name(@issue)}
        class="flex items-center justify-center w-4 shrink-0"
      >
        <.status_icon state={Issue.calculate_shown_state(@issue)} />
        <span class="sr-only">{Issue.calculate_status_name(@issue)}</span>
      </span>

      <.live_component
        :if={not @dimmed}
        module={StatusPicker}
        id={"status-picker-#{@key}"}
        issue={@issue}
        current_scope={@current_scope}
      />

      <span class="flex-1 min-w-0 flex items-center gap-1.5">
        <span
          :if={@issue.workflow}
          id={"issue-workflow-#{@key}"}
          title={"Opened by the #{Workflow.name(@issue.workflow)} workflow"}
          class="flex shrink-0"
        >
          <.icon name="pi-repeat" class="h-4 w-4 text-slate-500 dark:text-slate-400" />
        </span>
        <span :if={@issue.workflow} class="sr-only">
          From the {Workflow.name(@issue.workflow)} workflow:
        </span>
        <span
          data-qa="issue-title"
          title={@issue.title}
          class="min-w-0 truncate text-sm font-medium text-slate-900 dark:text-slate-100"
        >
          {@issue.title}
        </span>
      </span>

      <%!-- LiveView reads clicks at the window, so a stop here would silence Start: an actionable row stops per link. --%>
      <div
        class="flex items-center gap-2 shrink-0"
        onclick={!@actionable && "event.stopPropagation()"}
      >
        <span
          :if={@sub_issues > 0}
          data-qa="issue-sub-issue-count"
          title={"#{@sub_issues_done} of #{@sub_issues} sub-issues done"}
          class="inline-flex items-center gap-1 h-6 px-2 rounded-full border border-slate-200 dark:border-slate-700 text-xs text-slate-600 dark:text-slate-300 whitespace-nowrap"
        >
          <.icon name="pi-tree-structure" class="h-3.5 w-3.5 text-slate-500 dark:text-slate-400" />
          {@sub_issues_done}/{@sub_issues}<span class="sr-only"> sub-issues done</span>
        </span>

        <span
          :if={@open_blockers != []}
          data-qa="issue-blocked"
          title={@blocked_title}
          class="inline-flex items-center gap-1 h-6 px-2 rounded-full border border-red-300 dark:border-red-900 text-xs font-semibold text-red-700 dark:text-red-300"
        >
          <.icon name="pi-prohibit-bold" class="h-3.5 w-3.5" />
          {length(@open_blockers)}<span class="sr-only">{@blocked_title}</span>
        </span>

        <.link
          :if={@style}
          navigate={@path}
          id={"task-link-#{@issue.id}"}
          data-qa={"task-link-#{@issue.id}"}
          title={stage_label(@task, @run)}
          onclick="event.stopPropagation()"
          class={[
            "inline-flex items-center gap-1.5 h-6 px-2 rounded-full border text-xs font-medium whitespace-nowrap min-w-0 max-w-56 lg:max-w-32 xl:max-w-56 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500",
            @style.chip_class
          ]}
        >
          <.icon name={@style.icon} class="h-3.5 w-3.5 shrink-0" />
          <span class="truncate">{stage_label(@task, @run)}</span>
        </.link>

        <.link
          :if={@task != nil and not @actionable}
          navigate={~p"/tasks/#{@task.id}"}
          id={"task-link-#{@issue.id}"}
          data-qa={"task-link-#{@issue.id}"}
          class="inline-flex items-center gap-1.5 h-6 px-2 rounded-full border border-slate-200 dark:border-slate-700 text-xs text-slate-700 dark:text-slate-300 hover:bg-slate-100 dark:hover:bg-slate-700 transition-colors whitespace-nowrap"
        >
          <.icon name="pi-git-branch" class="h-3.5 w-3.5 text-slate-500 dark:text-slate-400" />
          <span>{stage_label(@task, @run)}</span>
        </.link>

        <button
          :if={@show_start}
          type="button"
          id={"issue-start-#{@key}"}
          phx-click="start_issue"
          phx-value-issue_id={@issue.id}
          aria-label={"Start #{@issue.identifier}"}
          class="inline-flex items-center gap-1.5 h-7 px-2.5 rounded-lg bg-blue-600 dark:bg-blue-500 text-white text-xs font-semibold hover:opacity-90 cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500"
        >
          <.icon name="pi-play" class="h-3.5 w-3.5" /> Start
        </button>

        <a
          :if={@issue.url not in [nil, ""]}
          href={@issue.url}
          target="_blank"
          rel="noopener noreferrer"
          data-qa="issue-external-link"
          title={"Open issue in #{Issue.tracker_label(@issue.tracker)}"}
          onclick={@actionable && "event.stopPropagation()"}
          class="p-1 rounded text-slate-400 hover:text-slate-900 dark:hover:text-slate-100 transition-colors focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500"
        >
          <.icon name="pi-arrow-square-out" class="h-4 w-4" />
        </a>

        <span
          :if={@issue.estimate}
          data-qa="issue-estimate"
          title={"#{@issue.estimate} points"}
          class="inline-flex items-center gap-1 h-6 px-2 rounded-full border border-slate-200 dark:border-slate-700 text-xs text-slate-600 dark:text-slate-300"
        >
          <.icon name="pi-triangle" class="h-3 w-3 text-slate-500 dark:text-slate-400" />
          {@issue.estimate}
        </span>

        <.assignee user={@issue.owner_user} />
      </div>
    </div>
    """
  end

  defp row_path(%Issue{} = issue, actionable, waiting, started) do
    cond do
      waiting -> waiting_path(waiting)
      actionable and started != nil -> ~p"/tasks/#{started.id}"
      true -> ~p"/issues/#{issue.identifier}"
    end
  end

  defp row_flag(false, _needs, _run), do: nil
  defp row_flag(true, false, _run), do: "border-l-transparent"

  defp row_flag(true, true, run) do
    if Run.state(run) == :failed,
      do: "border-l-red-500 bg-red-50 dark:bg-red-950/20",
      else: "border-l-amber-400 bg-amber-50 dark:bg-amber-950/20"
  end

  defp priority_label(priority), do: Issue.priority_label(priority) || "Medium"
end
