defmodule RailWeb.Components.IssueCard do
  @moduledoc false
  use RailWeb, :html

  import RailWeb.CoreComponents, only: [icon: 1, project_badge: 1]

  alias Rail.Domain.Formatters
  alias Rail.Issues.Schemas.Issue

  attr :issue, :map, required: true
  attr :task, :map, default: nil

  def issue_card(assigns) do
    body = card_body_for(assigns.issue)
    assigns = assign(assigns, :body, body)

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
        :if={@body != ""}
        data-qa="issue-body"
        class="text-xs text-slate-500 dark:text-slate-400 line-clamp-4 whitespace-pre-line leading-relaxed"
      >
        {@body}
      </p>

      <!-- Footer row: Dedicated Worktree info, Action button & Archive button -->
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
            <span>{Formatters.stage_label(@task)}</span>
            <.icon name="pi-arrow-square-out" class="h-3.5 w-3.5" />
          </.link>

          <button
            :if={@task == nil and not Issue.finished_state?(@issue.state)}
            type="button"
            id={"bring-local-#{@issue.id}"}
            data-qa={"bring_local_#{@issue.id}"}
            phx-click="bring_local"
            phx-value-issue_id={@issue.id}
            class="inline-flex items-center gap-1.5 px-3 py-1 rounded-lg bg-blue-600 dark:bg-blue-500 text-white text-xs font-semibold hover:opacity-90 transition-opacity cursor-pointer shadow-xs"
          >
            <.icon name="pi-arrow-down-left" class="h-3.5 w-3.5" />
            <span>Bring local</span>
          </button>

          <!-- Archive button -->
          <button
            type="button"
            id={"archive-issue-#{@issue.id}"}
            data-qa={"archive_issue_#{@issue.id}"}
            phx-click="open_archive"
            phx-value-issue_id={@issue.id}
            title="Archive issue"
            class="p-1.5 rounded-lg text-slate-500 dark:text-slate-400 hover:text-red-500 hover:bg-red-500/10 transition-colors cursor-pointer"
          >
            <.icon name="pi-trash" class="h-4 w-4" />
          </button>
        </div>
      </div>
    </div>
    """
  end

  def card_body_for(issue) do
    title = String.trim(Map.get(issue, :title) || "")
    desc = Map.get(issue, :description) || ""

    cond do
      desc == "" ->
        ""

      title != "" and String.starts_with?(desc, title) ->
        case String.split(desc, ~r/\r?\n/, parts: 2) do
          [_first_line, rest] -> String.trim(rest)
          [_single_line] -> ""
        end

      true ->
        desc
    end
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
