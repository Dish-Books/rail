defmodule RailWeb.Components.IssueCard do
  @moduledoc false
  use RailWeb, :html

  import RailWeb.CoreComponents, only: [icon: 1, project_badge: 1]

  alias Rail.Issues.Schemas.Issue
  alias RailWeb.Components.StageLabel

  attr :issue, :map, required: true
  attr :task, :map, default: nil
  attr :run, :any, default: nil

  def issue_card(assigns) do
    ~H"""
    <div
      id={"issue-card-#{@issue.id}"}
      data-qa={"issue-row issue-card-#{@issue.id}"}
      class="rounded-xl border border-slate-200 bg-slate-50 dark:border-slate-700 dark:bg-slate-800 p-5 cursor-pointer hover:border-slate-500 dark:hover:border-slate-400 transition-colors space-y-3"
      phx-click="open_editor"
      phx-value-issue_id={@issue.id}
    >
      <!-- Top row: ID pill, Project badge, Link, Title, Priority & Status badges -->
      <div class="flex items-center justify-between gap-3 flex-wrap">
        <div class="flex items-center gap-2 flex-wrap min-w-0 flex-1">
          <span
            data-qa="issue-identifier"
            class="px-2 py-0.5 rounded text-xs font-mono font-bold bg-blue-100 dark:bg-blue-900 text-blue-800 dark:text-blue-200 shrink-0"
          >
            {@issue.identifier}
          </span>

          <.project_badge project={@issue.project} />

          <a
            :if={@issue.url != nil and @issue.url != ""}
            href={@issue.url}
            target="_blank"
            rel="noopener noreferrer"
            data-qa="issue-external-link"
            title="Open issue in Linear"
            class="text-slate-500 dark:text-slate-400 hover:text-slate-900 dark:hover:text-slate-100 transition-colors p-0.5"
            onclick="event.stopPropagation()"
          >
            <.icon name="pi-arrow-square-out" class="h-4 w-4" />
          </a>

          <h3
            data-qa="issue-title"
            class="text-sm font-bold text-slate-900 dark:text-slate-100 truncate"
          >
            {@issue.title}
          </h3>
        </div>

        <div class="flex items-center gap-2 shrink-0">
          <span
            data-qa="issue-priority-badge"
            class={[
              "px-2 py-0.5 rounded border text-[10px] font-bold uppercase tracking-wider",
              priority_badge_class(@issue.priority)
            ]}
          >
            {priority_label(@issue.priority)}
          </span>

          <span
            data-qa="issue-status-badge"
            class="px-2 py-0.5 rounded bg-slate-200 dark:bg-slate-600 text-slate-600 dark:text-slate-300 text-[10px] font-bold uppercase tracking-wider"
          >
            {status_label(@issue.state)}
          </span>
        </div>
      </div>

      <!-- Card Body: deduplicated description up to 4 lines with ellipsis -->
      <p
        :if={@issue.description not in [nil, ""]}
        data-qa="issue-body"
        class="text-xs text-slate-500 dark:text-slate-400 line-clamp-4 whitespace-pre-line leading-relaxed"
      >
        {@issue.description}
      </p>

      <!-- Footer row: Dedicated Worktree info, Action button -->
      <div
        class="flex items-center justify-between pt-2 border-t border-slate-200 dark:border-slate-700 text-xs text-slate-500 dark:text-slate-400"
        onclick="event.stopPropagation()"
      >
        <div
          class="flex items-center gap-1.5 font-mono text-[11px] text-slate-500 dark:text-slate-400"
          data-qa="issue-worktree"
        >
          <.icon name="pi-git-fork" class="h-3.5 w-3.5 text-slate-500 dark:text-slate-400" />
          <span>Dedicated Worktree: .worktrees/{worktree_name(@issue)}</span>
        </div>

        <div class="flex items-center gap-2">
          <!-- Action button: Task stage link OR Bring local button OR nothing -->
          <.link
            :if={@task != nil}
            navigate={~p"/tasks/#{@task.id}"}
            id={"task-link-#{@issue.id}"}
            data-qa={"task-link-#{@issue.id}"}
            class="inline-flex items-center gap-1.5 px-3 py-1 rounded-lg bg-slate-200 dark:bg-slate-600 hover:bg-slate-100 dark:hover:bg-slate-700 text-slate-900 dark:text-slate-100 text-xs font-semibold transition-colors"
          >
            <span>{StageLabel.stage_label(@task, @run)}</span>
            <.icon name="pi-arrow-square-out" class="h-3.5 w-3.5" />
          </.link>

          <button
            :if={@task == nil and not Issue.finished_state?(@issue.state)}
            type="button"
            id={"start-product-run-#{@issue.id}"}
            data-qa={"start_product_run_#{@issue.id}"}
            phx-click="start_product_run"
            phx-value-issue_id={@issue.id}
            class="inline-flex items-center gap-1.5 px-3 py-1 rounded-lg bg-blue-600 dark:bg-blue-500 text-white text-xs font-semibold hover:opacity-90 transition-opacity cursor-pointer shadow-xs"
          >
            <.icon name="pi-arrow-down-left" class="h-3.5 w-3.5" />
            <span>Start</span>
          </button>
        </div>
      </div>
    </div>
    """
  end

  def worktree_name(issue) do
    cond do
      is_binary(issue.branch_name) and issue.branch_name != "" ->
        issue.branch_name

      is_binary(issue.identifier) and issue.identifier != "" ->
        issue.identifier
        |> String.downcase()
        |> String.replace(~r/[^a-z0-9_-]/, "-")

      true ->
        "issue-#{issue.id}"
    end
  end

  def priority_label(priority) do
    Issue.priority_label(priority) || "Medium"
  end

  def status_label(state) do
    Issue.state_label(state) || "Triage"
  end

  defp priority_badge_class(:urgent), do: "border-red-500 text-red-500 bg-red-500/10"
  defp priority_badge_class(:high), do: "border-orange-500 text-orange-500 bg-orange-500/10"
  defp priority_badge_class(:medium), do: "border-blue-500 text-blue-500 bg-blue-500/10"
  defp priority_badge_class(:low), do: "border-slate-400 text-slate-400 bg-slate-400/10"
  defp priority_badge_class(_other), do: "border-blue-500 text-blue-500 bg-blue-500/10"
end
