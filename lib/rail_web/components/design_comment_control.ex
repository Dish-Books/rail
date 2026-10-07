defmodule RailWeb.Components.DesignCommentControl do
  @moduledoc """
  The slim row right above a design's frame that turns commenting on and off, kept off the mockup so it never
  covers the part being commented on. Disabled, it says why.
  """
  use RailWeb, :html

  attr :commenting, :boolean, required: true
  attr :disabled_reason, :string, default: nil
  attr :target, :any, required: true

  def design_comment_control(assigns) do
    ~H"""
    <div
      id="design-comment-control"
      data-qa="design_comment_control"
      class="flex items-center gap-3 h-8 min-w-0"
    >
      <button
        :if={@disabled_reason}
        type="button"
        id="design-comment-toggle"
        data-qa="design_comment_toggle"
        disabled
        class="shrink-0 inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs font-semibold border border-slate-300 dark:border-slate-600 text-slate-900 dark:text-slate-100 opacity-50 cursor-not-allowed"
      >
        <.icon name="pi-cursor-click" class="size-[15px]" />Comment
      </button>

      <button
        :if={!@disabled_reason and not @commenting}
        type="button"
        id="design-comment-toggle"
        data-qa="design_comment_toggle"
        aria-pressed="false"
        phx-click="toggle_commenting"
        phx-target={@target}
        class="shrink-0 inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs font-semibold border border-slate-300 dark:border-slate-600 text-slate-900 dark:text-slate-100 hover:bg-slate-50 dark:hover:bg-slate-800 cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500"
      >
        <.icon name="pi-cursor-click" class="size-[15px]" />Comment<kbd class="ml-1 px-1 rounded border border-slate-300 dark:border-slate-600 font-mono text-[10px] font-normal text-slate-500 dark:text-slate-400">C</kbd>
      </button>

      <button
        :if={!@disabled_reason and @commenting}
        type="button"
        id="design-comment-toggle"
        data-qa="design_comment_toggle"
        aria-pressed="true"
        phx-click="toggle_commenting"
        phx-target={@target}
        class="shrink-0 inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs font-semibold bg-blue-600 dark:bg-blue-500 text-white shadow-xs cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500"
      >
        <.icon name="pi-cursor-click-fill" class="size-[15px]" />Commenting<kbd class="ml-1 px-1 rounded border border-blue-300/70 font-mono text-[10px] font-normal">Esc</kbd>
      </button>

      <span
        :if={@disabled_reason || @commenting}
        id="design-comment-hint"
        class="min-w-0 truncate text-[11.5px] text-slate-500 dark:text-slate-400"
      >
        {@disabled_reason || "Click an element to comment on it."}
      </span>
    </div>
    """
  end
end
