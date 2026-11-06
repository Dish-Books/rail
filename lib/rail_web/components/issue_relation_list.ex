defmodule RailWeb.Components.IssueRelationList do
  @moduledoc """
  Issues related to the one on the page, under a heading with their count: what blocks it, what it blocks, or its
  sub-issues. A finished one dims, and one in another project shows only its identifier and opens in its tracker.
  """
  use RailWeb, :html

  alias Rail.Issues.Schemas.Issue

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :count, :string, required: true
  # Each `%{issue: issue, in_project: boolean}`.
  attr :entries, :list, required: true
  attr :blocked, :boolean, default: false

  def issue_relation_list(assigns) do
    ~H"""
    <section id={@id} class="space-y-2">
      <h2 class="flex items-center gap-2 text-sm font-semibold text-slate-900 dark:text-slate-100">
        <.icon :if={@blocked} name="pi-prohibit-bold" class="h-4 w-4 text-red-600 dark:text-red-400" />
        <span>{@title}</span>
        <span class="text-xs font-normal text-slate-500 dark:text-slate-400">{@count}</span>
      </h2>
      <div class="rounded-xl border border-slate-200 dark:border-slate-700 divide-y divide-slate-200 dark:divide-slate-800 overflow-hidden">
        <.relation_row :for={entry <- @entries} list_id={@id} entry={entry} />
      </div>
    </section>
    """
  end

  attr :list_id, :string, required: true
  attr :entry, :map, required: true

  defp relation_row(%{entry: %{issue: issue, in_project: true}} = assigns) do
    assigns = assign(assigns, :issue, issue)

    ~H"""
    <.link
      navigate={~p"/issues/#{@issue.identifier}"}
      id={"#{@list_id}-#{@issue.identifier}"}
      class="flex items-center gap-3 h-10 px-3 hover:bg-slate-50 dark:hover:bg-slate-800/60 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500"
    >
      <.status_icon state={Issue.calculate_shown_state(@issue)} />
      <span class="w-20 shrink-0 text-xs font-mono text-slate-500 dark:text-slate-400 truncate">
        {@issue.identifier}
      </span>
      <span
        title={@issue.title}
        class={[
          "min-w-0 flex-1 truncate text-sm",
          if(Issue.finished_state?(@issue.state),
            do: "text-slate-500 dark:text-slate-400",
            else: "text-slate-900 dark:text-slate-100"
          )
        ]}
      >
        {@issue.title}
      </span>
      <span class="shrink-0 text-xs text-slate-500 dark:text-slate-400">{status_label(@issue)}</span>
    </.link>
    """
  end

  defp relation_row(%{entry: %{issue: issue}} = assigns) do
    assigns = assign(assigns, :issue, issue)

    ~H"""
    <a
      href={@issue.url}
      target="_blank"
      rel="noopener noreferrer"
      id={"#{@list_id}-#{@issue.identifier}"}
      class="flex items-center gap-3 h-10 px-3 hover:bg-slate-50 dark:hover:bg-slate-800/60 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500"
    >
      <.status_icon state={Issue.calculate_shown_state(@issue)} />
      <span class="w-20 shrink-0 text-xs font-mono text-slate-500 dark:text-slate-400 truncate">
        {@issue.identifier}
      </span>
      <span class="min-w-0 flex-1 truncate text-xs text-slate-500 dark:text-slate-400">
        In another project
      </span>
      <span class="shrink-0 text-xs text-slate-500 dark:text-slate-400">{status_label(@issue)}</span>
      <.icon name="pi-arrow-square-out" class="h-3.5 w-3.5 text-slate-400" />
    </a>
    """
  end

  defp status_label(%Issue{state_name: name, state: state}), do: name || Issue.state_label(state)
end
