defmodule RailWeb.Components.TaskTabs do
  @moduledoc """
  The row of tabs across a task's header: the issue it came from, then a tab per
  role, each saying what that role is doing.

  A tab is what the page shows in both columns at once - the role's work on the
  left and its conversation on the right - so the caller hands over tabs already
  worded and toned, and this only decides how they look.
  """
  use RailWeb, :html

  attr :tabs, :list, required: true

  def task_tabs(assigns) do
    ~H"""
    <div id="task-tabs" data-qa="task-tabs" class="flex items-end gap-1 -mb-px overflow-x-auto">
      <.tab :for={tab <- @tabs} tab={tab} />
    </div>
    """
  end

  attr :tab, :map, required: true

  defp tab(assigns) do
    ~H"""
    <button
      type="button"
      role="tab"
      id={"task-tab-#{@tab.id}"}
      data-qa="task-tab"
      aria-selected={to_string(@tab.selected?)}
      phx-click="select_tab"
      phx-value-tab={@tab.id}
      class={[
        "flex items-start gap-2 shrink-0 max-w-[15rem] px-4 pt-2.5 pb-3 rounded-t-xl border text-left cursor-pointer transition-colors",
        @tab.selected? &&
          "border-slate-200 dark:border-slate-700 border-b-white dark:border-b-slate-900 bg-white dark:bg-slate-900",
        not @tab.selected? && "border-transparent hover:bg-slate-100 dark:hover:bg-slate-800/60"
      ]}
    >
      <.tab_dot tone={@tab.tone} class="mt-1.5" />

      <span class="min-w-0">
        <span class="flex items-center gap-1.5">
          <span class={[
            "truncate text-sm",
            @tab.selected? && "font-semibold text-slate-900 dark:text-slate-100",
            not @tab.selected? && "font-medium text-slate-600 dark:text-slate-300"
          ]}>
            {@tab.label}
          </span>
          <.tab_badge count={@tab.badge} />
        </span>

        <span class="block truncate text-xs text-slate-500 dark:text-slate-400">
          {@tab.sublabel}
        </span>
      </span>
    </button>
    """
  end

  attr :tone, :atom, required: true
  attr :class, :string, default: nil

  defp tab_dot(assigns) do
    ~H"""
    <span
      data-qa="task-tab-dot"
      data-tone={@tone}
      class={[
        "h-2 w-2 shrink-0 rounded-full",
        @tone == :issue && "bg-violet-500",
        @tone == :running && "bg-blue-500 animate-pulse",
        @tone == :blocked && "bg-amber-500",
        @tone == :done && "bg-emerald-500",
        @tone == :failed && "bg-red-500",
        @tone in [:stopped, :idle] && "bg-slate-400 dark:bg-slate-600",
        @class
      ]}
    />
    """
  end

  attr :count, :integer, required: true

  defp tab_badge(assigns) do
    ~H"""
    <span
      :if={@count > 0}
      data-qa="task-tab-badge"
      class="inline-flex items-center justify-center min-w-[1.25rem] h-5 px-1.5 rounded-full text-[11px] font-semibold bg-amber-100 dark:bg-amber-950 text-amber-900 dark:text-amber-200"
    >
      {@count}
    </span>
    """
  end
end
