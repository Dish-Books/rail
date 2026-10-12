defmodule RailWeb.Components.ReviewSendCard do
  @moduledoc """
  A Send from the Review tray as it went out, in the conversation under its sender: what it sent, then a row for
  each finding, each changed ruling and each numbered comment.
  """
  use RailWeb, :html

  attr :id, :string, required: true
  attr :sender, :string, required: true
  attr :sent, :map, required: true, doc: "the note as `FixPlan.parse_note/1` reads it"

  def review_send_card(assigns) do
    ~H"""
    <div
      id={@id}
      data-qa="review_send_card"
      class="w-fit max-w-[88%] ml-auto mt-3.5 px-3 py-2 rounded-xl rounded-br-xs bg-slate-100 dark:bg-slate-800 border border-slate-200 dark:border-slate-700 text-slate-800 dark:text-slate-100 space-y-1.5"
    >
      <div class="flex items-center gap-1 min-w-0 text-[11px] font-semibold text-slate-500 dark:text-slate-400">
        <.icon name="pi-user" class="h-3 w-3 shrink-0" />
        <span data-qa="human-bubble-sender" class="shrink-0 whitespace-nowrap">{@sender}</span>
        <span data-qa="review_send_card_summary" class="min-w-0 truncate">· sent {@sent.summary}</span>
      </div>
      <p
        :for={title <- @sent.findings}
        data-qa="review_send_card_row"
        class="flex items-start gap-2 text-[12.5px]"
      >
        <span
          aria-hidden="true"
          class="mt-0.5 size-[18px] shrink-0 grid place-items-center rounded-full ring-1 ring-inset ring-slate-400 dark:ring-slate-500 text-slate-600 dark:text-slate-300"
        >
          <.icon name="pi-wrench-bold" class="size-[11px]" />
        </span>
        <span class="min-w-0 truncate">{title}</span>
      </p>
      <p
        :for={ruling <- @sent.rulings}
        data-qa="review_send_card_row"
        class="flex items-start gap-2 text-[12.5px]"
      >
        <span
          aria-hidden="true"
          class="mt-0.5 size-[18px] shrink-0 grid place-items-center rounded-full ring-1 ring-inset ring-slate-400 dark:ring-slate-500 text-slate-600 dark:text-slate-300"
        >
          <.icon name="pi-swap-bold" class="size-[11px]" />
        </span>
        <span class="min-w-0 wrap-anywhere">{ruling.title} · {ruling.now}, was {ruling.was}</span>
      </p>
      <p
        :for={comment <- @sent.comments}
        data-qa="review_send_card_row"
        class="flex items-start gap-2 text-[12.5px]"
      >
        <span
          aria-hidden="true"
          class="mt-0.5 size-[18px] shrink-0 grid place-items-center rounded-full text-[10px] font-bold bg-amber-400 text-slate-900"
        >
          {comment.number}
        </span>
        <span class="min-w-0 truncate">{comment.text}</span>
      </p>
    </div>
    """
  end
end
