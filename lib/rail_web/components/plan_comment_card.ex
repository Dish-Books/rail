defmodule RailWeb.Components.PlanCommentCard do
  @moduledoc """
  A round of plan comments as it went out, in the conversation under its sender: the message read back into its
  sections and numbered comments.
  """
  use RailWeb, :html

  attr :id, :string, required: true
  attr :sender, :string, required: true
  attr :round, :map, required: true, doc: "the message as `PlanComment.parse_message/1` reads it"

  def plan_comment_card(assigns) do
    ~H"""
    <div
      id={@id}
      data-qa="plan_comment_card"
      class="ml-auto mt-3.5 w-[92%] px-3 py-2 rounded-xl rounded-br-xs bg-slate-100 dark:bg-slate-800 border border-slate-200 dark:border-slate-700"
    >
      <div class="flex items-center gap-1 min-w-0 text-[11px] font-semibold text-slate-500 dark:text-slate-400">
        <.icon name="pi-user" class="h-3 w-3 shrink-0" />
        <span data-qa="human-bubble-sender" class="shrink-0 whitespace-nowrap">{@sender}</span>
        <span class="min-w-0 truncate font-normal">
          · {@round.count} {if @round.count == 1, do: "comment", else: "comments"} on the design
        </span>
      </div>
      <div :for={section <- @round.sections}>
        <p class="pt-1.5 text-[11px] font-semibold text-slate-600 dark:text-slate-300 truncate">
          {section.title} <span class="font-mono font-normal text-slate-500">{section.key}</span>
        </p>
        <div :for={comment <- section.comments} class="flex items-start gap-2 px-1.5 py-1 rounded-md">
          <span class="mt-0.5 size-[18px] shrink-0 grid place-items-center rounded-full bg-slate-700 text-white text-[10px] font-bold">
            {comment.number}
          </span>
          <div class="min-w-0 flex-1">
            <div class="flex items-center gap-1.5 min-w-0 font-mono text-[10.5px] text-slate-500 dark:text-slate-400">
              <span class="truncate" title={comment.selector}>{comment.selector}</span>
              <span class="shrink-0 max-w-[45%] truncate font-sans">
                {if comment.tag, do: "<#{comment.tag}>", else: ~s("#{comment.text}")}
              </span>
            </div>
            <p
              phx-no-format
              class="text-[12.5px] leading-[18px] text-slate-800 dark:text-slate-100 whitespace-pre-wrap wrap-break-word select-text"
            >{comment.body}</p>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
