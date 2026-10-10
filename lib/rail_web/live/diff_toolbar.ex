defmodule RailWeb.Live.DiffToolbar do
  @moduledoc """
  The diff pane's toolbar, a component of its own so that its counts move
  without patching every line of the pane. The commit picker leads it, and a picked
  commit says which first parent it is shown against. It folds at `@5xl` and again at
  `@3xl` of its own width, which is what a 1440 and a 1280 window leave it. A merge's
  view takes no comments, so it offers no Send.
  """
  use RailWeb, :live_component

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="diff-toolbar"
      data-qa="diff_toolbar"
      class="@container h-12 shrink-0 flex items-center gap-3 px-3 border-b border-slate-200 dark:border-slate-700"
    >
      <button
        type="button"
        id="diff-toggle-files"
        data-qa="diff_toggle_files"
        phx-click="toggle_file_list"
        phx-target={@target}
        aria-pressed={to_string(@show_file_tree)}
        title="Show or hide the file list"
        class="hidden @xl:grid size-8 shrink-0 place-items-center rounded-lg border border-slate-200 dark:border-slate-700 text-slate-500 dark:text-slate-400 hover:text-slate-900 dark:hover:text-slate-100 cursor-pointer"
      >
        <.icon name="pi-list" class="size-4" />
      </button>

      <.commit_picker
        view={@picker.view}
        history={@picker.history}
        dirty?={@picker.dirty?}
        target={@target}
      />

      <span
        :if={@picker.parent}
        data-qa="diff_first_parent"
        class="hidden @3xl:inline min-w-0 truncate text-[11px] text-slate-500 dark:text-slate-400"
      >
        {@picker.parent.short_sha} against its first parent
        <span class="font-mono">{@picker.parent.parent}</span>
      </span>

      <%!-- Wrap is this browser's choice, which the hook applies and tells the stage. --%>
      <.segmented_control
        id="diff-wrap"
        data-qa="diff_wrap"
        class="shrink-0"
        title="Long lines"
        phx-hook="DiffWrap"
        data-target={@target}
        options={[{:scroll, "Scroll", "pi-arrow-line-right"}, {:wrap, "Wrap", "pi-arrow-u-down-left"}]}
        selected={@wrap}
        event="select_diff_wrap"
        target={@target}
        value_name="wrap"
        option_qa="diff_wrap_option"
      />

      <%!-- Wrapped, since the stat's own display would beat a hidden class on it. --%>
      <span class="hidden @2xl:inline-flex shrink-0">
        <.diff_stat additions={@additions} deletions={@deletions} />
      </span>

      <div
        id="diff-viewed-progress"
        data-qa="diff_viewed_progress"
        class="shrink-0 flex items-center gap-2"
        title="Files you have marked read"
      >
        <div class="hidden @3xl:block h-1.5 w-16 rounded-full bg-slate-200 dark:bg-slate-700 overflow-hidden">
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
        :if={@unsent > 0 and @commentable?}
        data-qa="diff_comments_hint"
        class="hidden @5xl:inline-flex items-center gap-1.5 text-[11px] text-slate-500 dark:text-slate-400 whitespace-nowrap"
      >
        <span class={[
          "size-1.5 rounded-full",
          @running? && "bg-green-500",
          not @running? && "bg-slate-400"
        ]} />
        {hint(@agent, @running?)}
      </span>

      <%!-- The pane is marked loading from the click until the reply that redraws every comment as Sent. --%>
      <button
        :if={@unsent > 0 and @commentable?}
        type="button"
        id="send-diff-comments"
        data-qa="send_diff_comments"
        data-busy-self
        phx-click={JS.push("send_diff_comments", target: @target, loading: "#diff-pane")}
        title={hint(@agent, @running?)}
        class="shrink-0 inline-flex items-center justify-center gap-1.5 px-3 py-1.5 rounded-lg text-xs font-semibold bg-blue-600 dark:bg-blue-500 text-white hover:opacity-90 shadow-xs cursor-pointer whitespace-nowrap group-[.phx-click-loading]/diff:opacity-60 group-[.phx-click-loading]/diff:pointer-events-none"
      >
        <span class="inline-flex group-[.phx-click-loading]/diff:hidden items-center gap-1.5">
          <.icon name="pi-paper-plane-tilt" class="size-4" />
          <span>
            Send {@unsent}<span data-qa="send_noun" class="hidden @3xl:inline">{noun(@unsent)}</span>
          </span>
        </span>
        <span
          data-qa="send_diff_comments_sending"
          class="hidden group-[.phx-click-loading]/diff:inline-flex items-center gap-1.5"
        >
          <.icon name="pi-circle-notch-bold" class="size-4 motion-safe:animate-spin" />Sending {@unsent}
        </span>
      </button>

      <span
        :if={not @commentable?}
        data-qa="diff_no_comments"
        title="No comments on a merge"
        class="shrink-0 inline-flex items-center gap-1.5 text-[11px] text-slate-500 dark:text-slate-400 whitespace-nowrap"
      >
        <.icon name="pi-chat-slash" class="size-3.5" />
        <span class="hidden @3xl:inline">No comments on a merge</span>
      </span>
    </div>
    """
  end

  defp read(0, _viewed), do: 0
  defp read(total, viewed), do: div(viewed * 100, total)

  defp hint(agent, true), do: "#{agent} is working. These wait until its turn ends."
  defp hint(agent, false), do: "#{agent} is idle and starts on these at once."

  defp noun(1), do: " comment"
  defp noun(_unsent), do: " comments"
end
