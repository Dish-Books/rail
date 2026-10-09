defmodule RailWeb.Components.DiffPane do
  @moduledoc """
  The diff, as a toolbar over a file list beside the changes themselves.

  It draws the parts `RailWeb.Utils.CalculateDiffPane` worked out, so it decides
  nothing about the diff. Every event it raises goes to `@target`, so the view
  owning the diff decides what selecting, expanding, filtering and marking read
  actually do. The toolbar, the file list and each file are live components of
  their own, because the browser redraws everything under whatever a patch
  touches, and each part is an attribute of its own so a change reaches only it.
  Under 576px of its own width it leaves the file list out, as the Review tab's
  Diff item is beside a narrow window's conversation.
  """
  use RailWeb, :html

  import RailWeb.Utils.DiffFileName

  alias RailWeb.Live.DiffFile
  alias RailWeb.Live.DiffFileTree
  alias RailWeb.Live.DiffToolbar

  attr :frame, :map, required: true, doc: "what draws the pane whole: its sections, empty state and stray comments"
  attr :toolbar, :map, required: true
  attr :tree, :map, default: nil, doc: "the file list, `nil` while there are no files"
  attr :sections, :list, required: true, doc: "each file's id with what its component draws"
  attr :reader_id, :string, default: nil
  attr :target, :any, default: nil

  def diff_pane(assigns) do
    ~H"""
    <%!-- Send marks the pane loading until its reply lands, which each unsent comment reads as Sending. --%>
    <div
      id="diff-pane"
      data-qa="diff-pane diff_pane"
      data-busy-self
      class="@container group/diff flex flex-col h-full"
    >
      <.live_component module={DiffToolbar} id="diff-toolbar" {@toolbar} />

      <div
        :if={@frame.empty_message}
        id="diff-empty-state"
        data-qa="diff_empty_state"
        class="flex-1 flex flex-col items-center justify-center text-center p-8"
      >
        <.icon name="pi-check-circle" class="w-12 h-12 text-emerald-600 mb-3" />
        <p class="text-sm font-medium text-slate-900 dark:text-slate-100">
          {@frame.empty_message}
        </p>

        <div :if={@frame.stray != []} class="mt-6 w-full max-w-4xl space-y-3 text-left">
          <.stray_comments
            :for={{path, comments} <- @frame.stray}
            name={diff_file_name(%{display_path: path})}
            comments={comments}
            reader_id={@reader_id}
            target={@target}
          />
        </div>
      </div>

      <div :if={@tree} class="flex-1 min-h-0 flex">
        <.live_component module={DiffFileTree} id="diff-file-tree" {@tree} />

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
            data-scroll-to={@frame.scroll_to}
          >
            <p
              :if={@frame.no_match}
              data-qa="diff_no_match"
              class="py-10 text-center text-sm text-slate-500 dark:text-slate-400"
            >
              No file here matches {@frame.no_match}.
            </p>

            <.live_component
              :for={{id, section} <- @sections}
              :key={id}
              module={DiffFile}
              id={id}
              {section}
            />

            <.stray_comments
              :for={{path, comments} <- @frame.stray}
              name={diff_file_name(%{display_path: path})}
              comments={comments}
              reader_id={@reader_id}
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
  attr :reader_id, :string, required: true
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
          mine?={comment.user_id == @reader_id}
        />
      </div>
    </div>
    """
  end
end
