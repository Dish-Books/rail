defmodule RailWeb.Components.IssueCard do
  @moduledoc """
  One issue as a single row of the issues list: priority, identifier, status and
  title on the left; where its work stands, its points and who owns it on the
  right. Clicking the row opens the issue's page.
  """
  use RailWeb, :html

  alias Phoenix.LiveView.JS
  alias Rail.Issues.Schemas.Issue

  attr :issue, :map, required: true
  attr :task, :map, default: nil
  attr :run, :any, default: nil

  def issue_card(assigns) do
    ~H"""
    <div
      id={"issue-card-#{@issue.id}"}
      data-qa={"issue-row issue-card-#{@issue.id}"}
      class="group flex items-center gap-3 h-11 px-4 cursor-pointer hover:bg-slate-50 dark:hover:bg-slate-800/60 transition-colors"
      phx-click={JS.navigate(~p"/issues/#{@issue.identifier}")}
    >
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
        <.status_icon state={@issue.state} />
        <span class="sr-only">{status_label(@issue)}</span>
      </span>

      <span
        data-qa="issue-title"
        title={@issue.title}
        class="flex-1 min-w-0 truncate text-sm font-medium text-slate-900 dark:text-slate-100"
      >
        {@issue.title}
      </span>

      <div class="flex items-center gap-2 shrink-0" onclick="event.stopPropagation()">
        <.link
          :if={@task != nil}
          navigate={~p"/tasks/#{@task.id}"}
          id={"task-link-#{@issue.id}"}
          data-qa={"task-link-#{@issue.id}"}
          class="inline-flex items-center gap-1.5 h-6 px-2 rounded-full border border-slate-200 dark:border-slate-700 text-xs text-slate-700 dark:text-slate-300 hover:bg-slate-100 dark:hover:bg-slate-700 transition-colors"
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
          title="Open issue in Linear"
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
