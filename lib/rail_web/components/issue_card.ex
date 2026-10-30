defmodule RailWeb.Components.IssueCard do
  @moduledoc """
  One issue as a single row of the issues list: priority, identifier, status and
  title on the left, marked when a workflow opened it; its sub-issues done, its open
  blockers, where its work stands, its points and who owns it on the right. Clicking
  the row opens the issue's page. A sub-issue is indented, and a dimmed copy of a
  parent is context only.
  """
  use RailWeb, :html

  alias Phoenix.LiveView.JS
  alias Rail.Issues.Schemas.Issue
  alias Rail.Workflows.Schemas.Workflow

  attr :issue, :map, required: true
  attr :task, :map, default: nil
  attr :run, :any, default: nil
  # A parent can show more than once on a page, so each row brings its own key; it defaults to the issue's id.
  attr :row_key, :string, default: nil
  attr :nested, :boolean, default: false
  attr :dimmed, :boolean, default: false
  attr :open_blockers, :list, default: []

  def issue_card(assigns) do
    {done, total} = Issue.calculate_sub_issue_count(assigns.issue)
    blocker_names = Enum.map_join(assigns.open_blockers, ", ", & &1.issue.identifier)

    assigns =
      assigns
      |> assign(:key, assigns.row_key || assigns.issue.id)
      |> assign(:sub_issues_done, done)
      |> assign(:sub_issues, total)
      |> assign(:blocked_title, "Blocked by #{blocker_names}")

    ~H"""
    <div
      id={"issue-card-#{@key}"}
      data-qa={"issue-row issue-card-#{@issue.id}"}
      data-context={@dimmed && "true"}
      class={[
        "group flex items-center gap-3 h-11 px-4 cursor-pointer hover:bg-slate-50 dark:hover:bg-slate-800/60 transition-colors",
        @dimmed && "opacity-60"
      ]}
      phx-click={JS.navigate(~p"/issues/#{@issue.identifier}")}
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
        data-qa="issue-status-badge"
        title={status_label(@issue)}
        class="flex items-center justify-center w-4 shrink-0"
      >
        <.status_icon state={Issue.calculate_shown_state(@issue)} />
        <span class="sr-only">{status_label(@issue)}</span>
      </span>

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

      <div class="flex items-center gap-2 shrink-0" onclick="event.stopPropagation()">
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
          :if={@task != nil}
          navigate={~p"/tasks/#{@task.id}"}
          id={"task-link-#{@issue.id}"}
          data-qa={"task-link-#{@issue.id}"}
          class="inline-flex items-center gap-1.5 h-6 px-2 rounded-full border border-slate-200 dark:border-slate-700 text-xs text-slate-700 dark:text-slate-300 hover:bg-slate-100 dark:hover:bg-slate-700 transition-colors whitespace-nowrap"
        >
          <.icon name="pi-git-branch" class="h-3.5 w-3.5 text-slate-500 dark:text-slate-400" />
          <span>{stage_label(@task, @run)}</span>
        </.link>

        <a
          :if={@issue.url not in [nil, ""]}
          href={@issue.url}
          target="_blank"
          rel="noopener noreferrer"
          data-qa="issue-external-link"
          title={"Open issue in #{Issue.tracker_label(@issue.tracker)}"}
          class="p-1 rounded text-slate-400 hover:text-slate-900 dark:hover:text-slate-100 transition-colors"
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

  defp priority_label(priority), do: Issue.priority_label(priority) || "Medium"

  # Linear's own name first, as the issue page shows it, since several Linear states share one Rail state.
  defp status_label(%{state_name: state_name, state: state}), do: state_name || Issue.state_label(state) || "Triage"
end
