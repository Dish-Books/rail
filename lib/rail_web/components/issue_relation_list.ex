defmodule RailWeb.Components.IssueRelationList do
  @moduledoc """
  Issues related to the one on the page, under a heading with their count: what blocks it, what it blocks, or its
  sub-issues. A finished one dims, and one in another project shows only its identifier and opens in its tracker. A
  removable row sends `remove_relation` with its entry's `:remove` ids.
  """
  use RailWeb, :html

  alias Rail.Issues.Schemas.Issue

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :count, :string, required: true
  # Each `%{issue: issue, in_project: boolean}`.
  attr :entries, :list, required: true
  attr :blocked, :boolean, default: false
  # Each entry then also carries `remove: %{blocker_id: id, blocked_id: id}`.
  attr :removable, :boolean, default: false

  def issue_relation_list(assigns) do
    ~H"""
    <section id={@id} class="space-y-2">
      <h2 class="flex items-center gap-2 text-sm font-semibold text-slate-900 dark:text-slate-100">
        <.icon :if={@blocked} name="pi-prohibit-bold" class="h-4 w-4 text-red-600 dark:text-red-400" />
        <span>{@title}</span>
        <span class="text-xs font-normal text-slate-500 dark:text-slate-400">{@count}</span>
      </h2>
      <div class="rounded-xl border border-slate-200 dark:border-slate-700 divide-y divide-slate-200 dark:divide-slate-800 overflow-hidden">
        <.relation_row :for={entry <- @entries} list_id={@id} entry={entry} removable={@removable} />
      </div>
    </section>
    """
  end

  attr :list_id, :string, required: true
  attr :entry, :map, required: true
  attr :removable, :boolean, required: true

  # A button cannot sit inside a link, so a removable row links only its identifier and title.
  defp relation_row(%{entry: %{issue: issue, in_project: true, remove: remove}, removable: true} = assigns) do
    assigns = assigns |> assign(:issue, issue) |> assign(:remove, remove)

    ~H"""
    <div
      id={"#{@list_id}-#{@issue.identifier}"}
      class="group flex items-center gap-3 h-10 px-3 hover:bg-slate-50 dark:hover:bg-slate-800/60"
    >
      <.status_icon state={Issue.calculate_shown_state(@issue)} />
      <.link
        navigate={~p"/issues/#{@issue.identifier}"}
        id={"#{@list_id}-#{@issue.identifier}-link"}
        title={@issue.title}
        class="min-w-0 flex-1 flex items-center gap-3 rounded focus-visible:outline-2 focus-visible:outline-blue-500"
      >
        <span class="w-20 shrink-0 text-xs font-mono text-slate-500 dark:text-slate-400 truncate">
          {@issue.identifier}
        </span>
        <span class={[
          "min-w-0 flex-1 truncate text-sm hover:underline",
          if(Issue.finished_state?(@issue.state),
            do: "text-slate-500 dark:text-slate-400",
            else: "text-slate-900 dark:text-slate-100"
          )
        ]}>
          {@issue.title}
        </span>
      </.link>
      <span class="shrink-0 text-xs text-slate-500 dark:text-slate-400">{status_label(@issue)}</span>
      <button
        type="button"
        id={"#{@list_id}-#{@issue.identifier}-remove"}
        title={"Remove #{@issue.identifier}"}
        aria-label={"Remove #{@issue.identifier}"}
        phx-click="remove_relation"
        phx-value-blocker_id={@remove.blocker_id}
        phx-value-blocked_id={@remove.blocked_id}
        class="shrink-0 h-6 w-6 -mr-1 rounded-md flex items-center justify-center text-slate-400 dark:text-slate-500 opacity-0 group-hover:opacity-100 group-focus-within:opacity-100 focus-visible:opacity-100 pointer-coarse:opacity-100 hover:bg-slate-200 dark:hover:bg-slate-700 hover:text-slate-900 dark:hover:text-slate-100 cursor-pointer focus-visible:outline-2 focus-visible:outline-blue-500"
      >
        <.icon name="pi-x" class="h-4 w-4" />
      </button>
    </div>
    """
  end

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
