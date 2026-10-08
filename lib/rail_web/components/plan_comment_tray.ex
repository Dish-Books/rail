defmodule RailWeb.Components.PlanCommentTray do
  @moduledoc """
  The reader's unsent plan comments, above the Plan composer as the message they will become, with Send beside
  them while Plan can take a message. Only their author sees them.
  """
  use RailWeb, :html

  attr :comments, :list, required: true, doc: "the reader's unsent comments in round order, numbered as their cards"
  attr :missing, :list, default: [], doc: "the ids of comments whose element the frame last could not find"
  attr :changed, :list, default: [], doc: "the ids of ticket and plan comments whose line no longer reads as it did"
  attr :open, :boolean, default: true
  attr :can_send, :boolean, required: true
  attr :plan_running, :boolean, required: true
  attr :target, :any, required: true

  def plan_comment_tray(assigns) do
    assigns =
      assigns
      |> assign(:count, length(assigns.comments))
      |> assign(:rows, Enum.with_index(assigns.comments, 1))
      |> assign(:dashed, assigns.missing ++ assigns.changed)

    ~H"""
    <div
      :if={@comments != []}
      id="plan-comment-tray"
      data-qa="plan_comment_tray"
      class="shrink-0 border-t border-slate-200 dark:border-slate-700 bg-slate-50 dark:bg-slate-800/40"
    >
      <div class="flex items-center gap-2 px-4 pt-3 pb-1 min-w-0">
        <button
          type="button"
          id="plan-comment-tray-fold"
          aria-expanded={to_string(@open)}
          aria-label={if @open, do: "Fold the comments not sent", else: "Show the comments not sent"}
          phx-click="toggle_plan_comment_tray"
          phx-target={@target}
          class="size-5 shrink-0 grid place-items-center rounded text-slate-500 dark:text-slate-400 hover:text-slate-900 dark:hover:text-slate-100 cursor-pointer"
        >
          <.icon name={if @open, do: "pi-caret-down", else: "pi-caret-right"} class="size-[13px]" />
        </button>
        <span class="shrink-0 text-[10px] font-bold uppercase tracking-[0.12em] text-slate-500 dark:text-slate-400">
          Not sent <span id="plan-comment-tray-count" class="font-mono">{@count}</span>
        </span>
        <span class="min-w-0 text-[11px] text-slate-500 dark:text-slate-400 truncate">only you see these</span>
        <span class="ml-auto" />
        <button
          :if={@can_send}
          type="button"
          id="send-plan-comments"
          data-qa="send_plan_comments"
          phx-click="send_plan_comments"
          phx-disable-with="Sending…"
          phx-target={@target}
          title={hint(@plan_running)}
          class="shrink-0 inline-flex items-center justify-center gap-1.5 px-3 py-1.5 rounded-lg text-xs font-semibold bg-blue-600 dark:bg-blue-500 text-white hover:opacity-90 shadow-xs whitespace-nowrap cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500 disabled:opacity-50"
        >
          <.icon name="pi-paper-plane-tilt" class="size-4" />
          <span>Send {@count}<span>{noun(@count)}</span></span>
        </button>
      </div>

      <div :if={@open} class="px-2 pb-1 max-h-60 overflow-y-auto">
        <div
          :for={{comment, number} <- @rows}
          id={"plan-comment-#{comment.id}"}
          data-qa="plan_comment_row"
          data-found={to_string(comment.id not in @dashed)}
          class="flex items-start gap-2.5 px-2 py-2 rounded-lg hover:bg-slate-200/50 dark:hover:bg-slate-700/40"
        >
          <span
            aria-hidden="true"
            class={[
              "mt-0.5 size-[18px] shrink-0 grid place-items-center rounded-full text-[10px] font-bold",
              comment.id not in @dashed && "bg-amber-400 text-slate-900",
              comment.id in @dashed &&
                "border-[1.5px] border-dashed border-slate-500 text-slate-400"
            ]}
          >
            {number}
          </span>
          <div class="min-w-0 flex-1">
            <div class="flex items-center gap-1.5 min-w-0 font-mono text-[10.5px] text-slate-500 dark:text-slate-400">
              <span
                :if={comment.target != :design}
                class="shrink-0 font-sans font-semibold text-slate-600 dark:text-slate-300"
              >
                {if comment.target == :ticket, do: "Ticket", else: "Plan"}
              </span>
              <span :if={comment.target != :design} class="truncate">{comment.element_label}</span>
              <span :if={comment.target == :design} class="truncate" title={comment.selector}>
                {comment.selector}
              </span>
              <span class="shrink-0 max-w-[40%] truncate font-sans text-slate-600 dark:text-slate-300">
                {element(comment)}
              </span>
              <span
                :if={comment.id in @missing}
                data-qa="plan_comment_missing"
                class="inline-flex items-center gap-1 rounded px-1.5 py-0.5 text-[10px] font-sans font-bold uppercase tracking-wider shrink-0 bg-slate-200 dark:bg-slate-700 text-slate-700 dark:text-slate-200"
              >
                <.icon name="pi-eye-slash-bold" class="size-[11px]" />No longer found
              </span>
              <span
                :if={comment.id in @changed}
                data-qa="plan_comment_changed"
                class="inline-flex items-center gap-1 rounded px-1.5 py-0.5 text-[10px] font-sans font-bold uppercase tracking-wider shrink-0 bg-slate-200 dark:bg-slate-700 text-slate-700 dark:text-slate-200"
              >
                <.icon name="pi-arrows-clockwise-bold" class="size-[11px]" />Changed
              </span>
              <button
                type="button"
                id={"remove-plan-comment-#{comment.id}"}
                data-qa="remove_plan_comment"
                phx-click="remove_plan_comment"
                phx-value-id={comment.id}
                phx-target={@target}
                class="ml-auto shrink-0 inline-flex items-center gap-1 px-2 py-0.5 rounded font-sans text-[11px] font-semibold text-slate-500 dark:text-slate-400 hover:text-slate-900 dark:hover:text-slate-100 hover:bg-slate-100 dark:hover:bg-slate-800 cursor-pointer focus-visible:outline-2 focus-visible:outline-blue-500"
              >
                <.icon name="pi-trash" class="size-[13px]" />Remove
              </button>
            </div>
            <p class={[
              "mt-0.5 text-[12.5px] leading-[18px] line-clamp-2 wrap-break-word",
              comment.id not in @dashed && "text-slate-800 dark:text-slate-100",
              comment.id in @dashed && "text-slate-500 dark:text-slate-400"
            ]}>
              {comment.body}
            </p>
          </div>
        </div>
      </div>

      <div :if={@open and @can_send} id="plan-comment-tray-hint" class="px-4 pb-2.5">
        <span class="inline-flex items-center gap-1.5 text-[11px] text-slate-500 dark:text-slate-400 whitespace-nowrap min-w-0">
          <span class={[
            "size-1.5 shrink-0 rounded-full",
            @plan_running && "bg-green-500",
            not @plan_running && "bg-slate-400"
          ]} />
          <span class="truncate">{hint(@plan_running)}</span>
        </span>
      </div>
    </div>
    """
  end

  defp element(%{target: :design, element_text: ""} = comment), do: "<#{comment.element_tag}>"
  defp element(comment), do: ~s("#{comment.element_text}")

  defp hint(true), do: "Plan is working. These wait until its turn ends."
  defp hint(false), do: "Plan is idle and starts on these at once."

  defp noun(1), do: " comment"
  defp noun(_count), do: " comments"
end
