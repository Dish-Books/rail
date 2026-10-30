defmodule RailWeb.Components.FindingIssue do
  @moduledoc """
  The card at the top of a finding ruled New issue: the issue Send files, as it will be filed, and once filed the
  issue it became, linked in its tracker.
  """
  use RailWeb, :html

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.Finding

  attr :finding, Finding, required: true, doc: "ruled New issue, its issue loaded"
  attr :preview, :map, default: nil, doc: "`Rail.Pipeline.Schemas.Finding.calculate_issue/2`, until it is filed"
  attr :project_name, :string, required: true

  def finding_issue(%{finding: %Finding{issue: %Issue{} = issue}} = assigns) do
    assigns =
      assigns
      |> assign(:issue, issue)
      |> assign(:state, issue.state_name || Issue.state_label(issue.state))
      |> assign(:priority, priority(issue.priority))
      |> assign(:tracker, Issue.tracker_label(issue.tracker))

    ~H"""
    <section
      id="finding-issue"
      data-qa="finding_issue"
      data-filed="true"
      aria-label="The issue it became"
      class="rounded-xl border border-slate-200 dark:border-slate-700 overflow-hidden"
    >
      <div class="flex flex-wrap items-center gap-x-2 gap-y-1 px-4 py-2.5 bg-slate-50 dark:bg-slate-800/60 border-b border-slate-200 dark:border-slate-700 text-[12px]">
        <.icon name="pi-arrow-square-out-bold" class="size-3.5 text-slate-500 dark:text-slate-400" />
        <span class="font-semibold text-slate-700 dark:text-slate-200">
          Filed as <span class="font-mono">{@issue.identifier}</span>
        </span>
        <span class="text-slate-500 dark:text-slate-400">
          · {@state} · {@priority}
        </span>
        <a
          id="finding-issue-open"
          data-qa="finding_issue_open"
          href={@issue.url}
          target="_blank"
          rel="noopener noreferrer"
          class="ml-auto inline-flex items-center gap-1 font-semibold text-blue-600 dark:text-blue-400 hover:underline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500 rounded-sm"
        >
          Open in {@tracker}<.icon name="pi-arrow-up-right" class="size-3" />
        </a>
      </div>
      <div class="px-4 py-3">
        <p class="text-[14px] font-semibold text-slate-900 dark:text-slate-100 wrap-anywhere">
          {@issue.title}
        </p>
        <p class="mt-1 text-[12px] text-slate-500 dark:text-slate-400">
          Its ruling can no longer change.
        </p>
      </div>
    </section>
    """
  end

  def finding_issue(assigns) do
    assigns = assign(assigns, :priority, priority(assigns.preview.priority))

    ~H"""
    <section
      id="finding-issue"
      data-qa="finding_issue"
      data-filed="false"
      aria-label="The issue Send files"
      class="rounded-xl border border-slate-200 dark:border-slate-700 overflow-hidden"
    >
      <div class="flex flex-wrap items-center gap-x-2 gap-y-1 px-4 py-2.5 bg-slate-50 dark:bg-slate-800/60 border-b border-slate-200 dark:border-slate-700 text-[12px]">
        <.icon name="pi-plus-square-bold" class="size-3.5 text-slate-500 dark:text-slate-400" />
        <span class="font-semibold text-slate-700 dark:text-slate-200">Filed when you send</span>
        <span class="ml-auto min-w-0 wrap-anywhere text-slate-500 dark:text-slate-400">
          {@project_name} · Triage · {@priority}
        </span>
      </div>
      <div class="px-4 py-3 space-y-2">
        <p
          data-qa="finding_issue_title"
          class="text-[14px] font-semibold text-slate-900 dark:text-slate-100 wrap-anywhere"
        >
          {@preview.title}
        </p>
        <div data-qa="finding_issue_description" class="wrap-anywhere">
          <.markdown
            content={@preview.description}
            class="text-[12.5px] prose-p:my-1.5 prose-code:before:content-none prose-code:after:content-none"
          />
        </div>
      </div>
    </section>
    """
  end

  defp priority(priority), do: "#{Issue.priority_label(priority)} priority"
end
