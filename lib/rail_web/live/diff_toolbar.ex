defmodule RailWeb.Live.DiffToolbar do
  @moduledoc """
  The diff pane's toolbar, a component of its own so that its counts move
  without patching every line of the pane.
  """
  use RailWeb, :live_component

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="diff-toolbar"
      data-qa="diff_toolbar"
      class="h-12 shrink-0 flex items-center gap-3 px-3 border-b border-slate-200 dark:border-slate-700"
    >
      <button
        type="button"
        id="diff-toggle-files"
        data-qa="diff_toggle_files"
        phx-click="toggle_file_list"
        phx-target={@target}
        aria-pressed={to_string(@show_file_tree)}
        title="Show or hide the file list"
        class="size-8 shrink-0 grid place-items-center rounded-lg border border-slate-200 dark:border-slate-700 text-slate-500 dark:text-slate-400 hover:text-slate-900 dark:hover:text-slate-100 cursor-pointer"
      >
        <.icon name="pi-list" class="size-4" />
      </button>

      <.segmented_control
        id="diff-filter"
        data-qa="diff_filter"
        class="shrink-0"
        options={[branch: "All changes", uncommitted: "Uncommitted"]}
        selected={@filter}
        event="select_diff_filter"
        target={@target}
        value_name="filter"
        option_qa="diff_filter_option"
      />

      <.diff_stat additions={@additions} deletions={@deletions} class="shrink-0" />

      <div
        id="diff-viewed-progress"
        data-qa="diff_viewed_progress"
        class="shrink-0 flex items-center gap-2"
        title="Files you have marked read"
      >
        <div class="h-1.5 w-16 rounded-full bg-slate-200 dark:bg-slate-700 overflow-hidden">
          <div class="h-full rounded-full bg-emerald-500" style={"width: #{read(@total, @viewed)}%;"} />
        </div>
        <span class="font-mono text-[11px] tabular-nums text-slate-500 dark:text-slate-400">
          {@viewed}/{@total}
        </span>
      </div>

      <form
        id="diff-file-filter"
        phx-change="filter_diff_files"
        phx-target={@target}
        class="flex-1 min-w-0 flex items-center gap-2"
      >
        <.icon name="pi-magnifying-glass" class="size-3.5 text-slate-400 dark:text-slate-500" />
        <input
          type="text"
          name="query"
          value={@query}
          placeholder="Filter"
          autocomplete="off"
          phx-debounce="150"
          id="diff-file-query"
          data-qa="diff_file_query"
          class="w-full bg-transparent border-0 p-0 text-xs text-slate-900 dark:text-slate-100 placeholder:text-slate-400 dark:placeholder:text-slate-500 focus:ring-0"
        />
      </form>

      <span
        :if={@unsent > 0}
        data-qa="diff_comments_hint"
        class="inline-flex items-center gap-1.5 text-[11px] text-slate-500 dark:text-slate-400 whitespace-nowrap"
      >
        <span class={[
          "size-1.5 rounded-full",
          @engineer_running? && "bg-green-500",
          not @engineer_running? && "bg-slate-400"
        ]} />
        {hint(@engineer_running?)}
      </span>

      <button
        :if={@unsent > 0}
        type="button"
        id="send-diff-comments"
        data-qa="send_diff_comments"
        phx-click="send_diff_comments"
        phx-target={@target}
        class="shrink-0 inline-flex items-center justify-center gap-1.5 px-3 py-1.5 rounded-lg text-xs font-semibold bg-blue-600 dark:bg-blue-500 text-white hover:opacity-90 shadow-xs cursor-pointer"
      >
        <.icon name="pi-paper-plane-tilt" class="size-4" />{send_label(@unsent)}
      </button>
    </div>
    """
  end

  defp read(0, _viewed), do: 0
  defp read(total, viewed), do: div(viewed * 100, total)

  defp hint(true), do: "Engineer is working. These wait until its turn ends."
  defp hint(false), do: "Engineer is idle and starts on these at once."

  defp send_label(1), do: "Send 1 comment"
  defp send_label(unsent), do: "Send #{unsent} comments"
end
