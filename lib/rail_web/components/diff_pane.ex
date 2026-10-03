defmodule RailWeb.Components.DiffPane do
  @moduledoc """
  The diff, as a toolbar over a file list beside the changes themselves.

  Everything it draws comes out of `Rail.Git.load_diff/4` ready to render, so
  this decides nothing about the diff. Every event it raises goes to `@target`,
  so the stage owning the diff decides what selecting, expanding, filtering and
  marking read actually do. The one thing it works out for itself is which files
  the reader's query leaves visible, because the counts in the toolbar are of the
  whole diff either way.

  The toolbar, the file list and each file are live components of their own,
  because the browser redraws everything under whatever a patch touches. What
  `RailWeb.Utils.CalculateDiffPane` returns is split the same way, so the stage
  can send a part that moved to that part alone.
  """
  use RailWeb, :html

  import RailWeb.Utils.CalculateDiffPane
  import RailWeb.Utils.DiffFileName

  alias RailWeb.Live.DiffFile
  alias RailWeb.Live.DiffFileTree
  alias RailWeb.Live.DiffToolbar

  attr :files, :list, default: []
  attr :expanded_gaps, :map, default: %{}
  attr :collapsed, :list, default: []
  attr :selected_file, :string, default: nil
  attr :show_file_tree, :boolean, default: true
  attr :filter, :atom, default: :branch
  attr :query, :string, default: ""
  attr :empty_message, :string, default: "Nothing has been changed on this branch yet."
  attr :scroll_to, :string, default: nil
  attr :target, :any, default: nil
  attr :comments, :list, default: [], doc: "the reader's comments on this task, whatever their state"
  attr :open_comments, :list, default: [], doc: "ids of the resolved comments the reader has unfolded"
  attr :comment_list, :atom, default: :files, doc: "which of files or comments the column beside the diff lists"
  attr :selected_comment, :string, default: nil
  attr :draft, :map, default: nil, doc: "the line a comment is being written on"
  attr :engineer_running?, :boolean, default: false

  def diff_pane(assigns) do
    assigns = assign(assigns, :pane, calculate_diff_pane(assigns))

    ~H"""
    <div id="diff-pane" data-qa="diff-pane diff_pane" class="flex flex-col h-full">
      <.live_component module={DiffToolbar} id="diff-toolbar" {@pane.toolbar} />

      <div
        :if={@pane.frame.empty_message}
        id="diff-empty-state"
        data-qa="diff_empty_state"
        class="flex-1 flex flex-col items-center justify-center text-center p-8"
      >
        <.icon name="pi-check-circle" class="w-12 h-12 text-emerald-600 mb-3" />
        <p class="text-sm font-medium text-slate-900 dark:text-slate-100">
          {@pane.frame.empty_message}
        </p>

        <div :if={@pane.frame.stray != []} class="mt-6 w-full max-w-4xl space-y-3 text-left">
          <.stray_comments
            :for={{path, comments} <- @pane.frame.stray}
            name={diff_file_name(%{display_path: path})}
            comments={comments}
            target={@target}
          />
        </div>
      </div>

      <div :if={@pane.tree} class="flex-1 min-h-0 flex">
        <.live_component module={DiffFileTree} id="diff-file-tree" {@pane.tree} />

        <div
          id="diff-row-list"
          data-qa="diff_row_list"
          class="flex-1 min-w-0 flex flex-col bg-slate-50 dark:bg-slate-800/30"
        >
          <%!-- A reader arriving from a finding is arriving at one file, so the
          scroller is told which section to put in front of them. --%>
          <div
            class="flex-1 overflow-y-auto px-3 pb-3 space-y-3 selection:bg-blue-500/20"
            phx-hook="DiffScroller"
            id="diff-scroller"
            data-scroll-to={@pane.frame.scroll_to}
          >
            <p
              :if={@pane.frame.no_match}
              data-qa="diff_no_match"
              class="py-10 text-center text-sm text-slate-500 dark:text-slate-400"
            >
              No file here matches {@pane.frame.no_match}.
            </p>

            <.live_component
              :for={{id, section} <- @pane.sections}
              :key={id}
              module={DiffFile}
              id={id}
              {section}
            />

            <.stray_comments
              :for={{path, comments} <- @pane.frame.stray}
              name={diff_file_name(%{display_path: path})}
              comments={comments}
              target={@target}
            />
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :name, :map, required: true
  attr :comments, :list, required: true, doc: "each comment and whether it is unfolded"
  attr :target, :any, required: true

  # A file this view does not draw, such as a committed one under Uncommitted,
  # still has its comments counted and sent, so they are shown after the rest.
  defp stray_comments(assigns) do
    assigns =
      assign(assigns, :unsent, Enum.count(assigns.comments, fn {comment, _open?} -> comment.status == :unsent end))

    ~H"""
    <div
      data-qa="diff_comment_stray_section"
      class="first:mt-3 rounded-xl border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-900 overflow-hidden"
    >
      <div class="h-11 px-3 flex items-center gap-2 bg-slate-100 dark:bg-slate-800 border-b border-slate-200 dark:border-slate-700">
        <span class="min-w-0 flex font-mono text-xs">
          <span class="truncate text-slate-500 dark:text-slate-400">{@name.dir}</span>
          <span class="shrink-0 font-bold text-slate-900 dark:text-slate-100">{@name.name}</span>
        </span>
        <span
          :if={@unsent > 0}
          class="ml-auto shrink-0 inline-flex items-center gap-1 rounded-full bg-amber-100 dark:bg-amber-950 px-2 py-0.5 text-[11px] font-semibold text-amber-800 dark:text-amber-300"
        >
          <.icon name="pi-chat-text-fill" class="size-3" />{@unsent} unsent
        </span>
      </div>

      <div class="px-4 py-2.5 space-y-2 bg-slate-50 dark:bg-slate-800/40">
        <.diff_comment
          :for={{comment, open?} <- @comments}
          comment={comment}
          target={@target}
          lifted?={true}
          open?={open?}
        />
      </div>
    </div>
    """
  end
end
