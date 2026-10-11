defmodule RailWeb.Components.ScreenComment do
  @moduledoc """
  One of the reader's unsent comments on a screen state, in the screen view beside the shot, shaped like an unsent
  diff comment. A sent one leaves the view and reads only in the conversation.
  """
  use RailWeb, :html

  attr :comment, :map, required: true
  attr :target, :any, required: true

  def screen_comment(assigns) do
    ~H"""
    <div
      id={"screen-comment-#{@comment.id}"}
      data-qa="screen_comment"
      class="rounded-r-lg border border-l-2 border-slate-200 dark:border-slate-700 border-l-amber-500 dark:border-l-amber-500 bg-white dark:bg-slate-900 px-3 py-1.5"
    >
      <div class="flex items-center gap-x-2 min-h-5 min-w-0">
        <span class="inline-flex items-center gap-1 text-[11px] font-semibold text-slate-500 dark:text-slate-400 shrink-0">
          <.icon name="pi-user" class="size-3" />You
        </span>
        <span class="inline-flex items-center gap-1 rounded px-1.5 py-0.5 text-[10px] font-bold uppercase tracking-wider shrink-0 bg-amber-100 dark:bg-amber-950 text-amber-800 dark:text-amber-300">
          Not sent
        </span>
        <button
          type="button"
          data-qa="screen_comment_remove"
          phx-click="remove_screen_comment"
          phx-value-id={@comment.id}
          phx-target={@target}
          class="ml-auto inline-flex items-center gap-1 px-2 py-0.5 rounded text-[11px] font-semibold text-slate-500 dark:text-slate-400 hover:text-slate-900 dark:hover:text-slate-100 hover:bg-slate-100 dark:hover:bg-slate-800 cursor-pointer shrink-0 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500"
        >
          <.icon name="pi-trash" class="size-3.5" />Remove
        </button>
      </div>
      <p
        phx-no-format
        class="mt-0.5 text-[13px] leading-[21px] text-slate-800 dark:text-slate-100 whitespace-pre-wrap break-words"
      >{@comment.body}</p>
    </div>
    """
  end
end
