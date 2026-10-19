defmodule RailWeb.Components.ReviewCommentTray do
  @moduledoc """
  What the Review tray's Send will send, above the Review lead's composer in send order: the findings ruled Fix,
  which every reader sees, then the reader's own unsent finding, diff and screen comments, numbered, with the gate's
  reason under them. Empty while the review is open and idle it offers Finish review; empty once finished it draws
  nothing. While a fix plan waits on approval it lists only what changed since the last Send: each ruling changed,
  then new comments, and offers no Finish review.
  """
  use RailWeb, :html

  alias Rail.Pipeline.Schemas.DiffComment
  alias Rail.Pipeline.Schemas.Finding

  @plan_unchanged "Changed rulings and comments you send now go to the lead, which saves a revised fix plan in place of this one."

  attr :fix, :list, required: true, doc: "the findings ruled Fix, in the Findings list's order"
  attr :finding_comments, :list, required: true, doc: "the reader's unsent finding comments, in send order"
  attr :diff_comments, :list, required: true, doc: "the reader's unsent diff comments, in send order"
  attr :screen_comments, :list, required: true, doc: "the reader's unsent screen comments, in send order"
  attr :rulings, :list, default: [], doc: "`%{key:, title:, was:, now:}` for each ruling changed since the last Send"

  attr :gate, :map,
    required: true,
    doc: "`%{working:, finished:, ci_failed:, saved:, plan:, undecided:}`, as the Review stage works it out"

  attr :open, :boolean, default: true
  attr :error, :string, default: nil, doc: "why the last Send was refused"
  attr :target, :any, required: true

  def review_comment_tray(assigns) do
    %{fix: fix, finding_comments: finding, diff_comments: diff, screen_comments: screen, gate: gate} = assigns
    comments = Enum.map(finding, &{:finding, &1}) ++ Enum.map(diff, &{:diff, &1}) ++ Enum.map(screen, &{:screen, &1})
    count = length(fix) + length(assigns.rulings) + length(comments)
    {hint, working} = hint(gate, fix ++ assigns.rulings, comments, assigns.error)

    assigns =
      assigns
      |> assign(:count, count)
      |> assign(:show_tray, count > 0 or not gate.finished)
      |> assign(:empty, count == 0)
      |> assign(:show_finish, count == 0 and not gate.working and not gate.plan)
      |> assign(:mine, comments != [])
      |> assign(:show_rows, assigns.open and count > 0)
      |> assign(
        :can_send,
        not gate.working and gate.saved and (count > 0 or (not gate.ci_failed and gate.undecided == 0))
      )
      |> assign(:comments, Enum.with_index(comments, 1))
      |> assign(:hint, hint)
      |> assign(:working, working)

    ~H"""
    <div
      :if={@show_tray}
      id="review-send-tray"
      data-qa="review_send_tray"
      class="shrink-0 border-t border-slate-200 dark:border-slate-700 bg-slate-50 dark:bg-slate-800/40"
    >
      <div class="flex items-center gap-2 px-4 pt-3 pb-1 min-w-0">
        <button
          :if={not @empty}
          type="button"
          id="review-send-tray-fold"
          aria-expanded={to_string(@open)}
          aria-label={if @open, do: "Fold the tray", else: "Show the tray"}
          phx-click="toggle_review_tray"
          phx-target={@target}
          class="size-5 shrink-0 grid place-items-center rounded text-slate-500 dark:text-slate-400 hover:text-slate-900 dark:hover:text-slate-100 cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500"
        >
          <.icon name={if @open, do: "pi-caret-down", else: "pi-caret-right"} class="size-[13px]" />
        </button>
        <span
          :if={not @empty}
          class="shrink-0 text-[10px] font-bold uppercase tracking-[0.12em] text-slate-500 dark:text-slate-400"
        >
          Not sent <span id="review-send-tray-count" class="font-mono">{@count}</span>
        </span>
        <span
          :if={@empty}
          class="shrink-0 text-[10px] font-bold uppercase tracking-[0.12em] text-slate-500 dark:text-slate-400"
        >
          Nothing to send
        </span>
        <span :if={@mine} class="min-w-0 text-[11px] text-slate-500 dark:text-slate-400 truncate">
          your comments only you see
        </span>
        <span class="ml-auto" />
        <button
          :if={not @empty}
          type="button"
          id="send-review-tray"
          data-qa="send_review_tray"
          phx-click="send_review_tray"
          phx-disable-with="Sending…"
          phx-target={@target}
          disabled={not @can_send}
          class="shrink-0 inline-flex items-center justify-center gap-1.5 px-3 py-1.5 rounded-lg text-xs font-semibold bg-blue-600 dark:bg-blue-500 text-white shadow-xs whitespace-nowrap hover:opacity-90 cursor-pointer disabled:opacity-50 disabled:cursor-not-allowed focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500"
        >
          <.icon name="pi-paper-plane-tilt" class="size-4" />Send {@count}
        </button>
        <button
          :if={@show_finish}
          type="button"
          id="finish-review"
          data-qa="finish_review"
          phx-click="send_review_tray"
          phx-disable-with="Finishing…"
          phx-target={@target}
          disabled={not @can_send}
          class="shrink-0 inline-flex items-center justify-center gap-1.5 px-3 py-1.5 rounded-lg text-xs font-semibold bg-blue-600 dark:bg-blue-500 text-white shadow-xs whitespace-nowrap hover:opacity-90 cursor-pointer disabled:opacity-50 disabled:cursor-not-allowed focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500"
        >
          <.icon name="pi-check" class="size-4" />Finish review
        </button>
      </div>

      <div :if={@show_rows} class="px-2 pb-1 max-h-60 overflow-y-auto">
        <button
          :for={finding <- @fix}
          type="button"
          id={"review-tray-finding-#{finding.key}"}
          data-qa="review_tray_finding"
          title="Open in Findings"
          phx-click="open_tray_finding"
          phx-value-key={finding.key}
          phx-target={@target}
          class="w-full flex items-start gap-2.5 px-2 py-2 rounded-lg text-left hover:bg-slate-200/50 dark:hover:bg-slate-700/40 cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500"
        >
          <span
            aria-hidden="true"
            class="mt-0.5 size-[18px] shrink-0 grid place-items-center rounded-full ring-1 ring-inset ring-slate-400 dark:ring-slate-500 text-slate-600 dark:text-slate-300"
          >
            <.icon name="pi-wrench-bold" class="size-[11px]" />
          </span>
          <span class="min-w-0 flex-1">
            <span class="flex items-center gap-1.5 min-w-0 text-[10.5px] text-slate-500 dark:text-slate-400">
              <span class="shrink-0 font-semibold text-slate-600 dark:text-slate-300">Fix finding</span>
              <span
                :if={Finding.where(finding)}
                class={["truncate", finding.kind == :code && "font-mono"]}
                title={Finding.where(finding)}
              >
                {where(finding)}
              </span>
              <span class="ml-auto shrink-0 inline-flex items-center gap-1 px-2 py-0.5 text-[11px] font-semibold text-slate-500 dark:text-slate-400">
                Open<.icon name="pi-arrow-right" class="size-3" />
              </span>
            </span>
            <span class="block mt-0.5 text-[12.5px] leading-[18px] truncate text-slate-800 dark:text-slate-100">
              {finding.title}
            </span>
          </span>
        </button>

        <button
          :for={ruling <- @rulings}
          type="button"
          id={"review-tray-ruling-#{ruling.key}"}
          data-qa="review_tray_ruling"
          title="Open in Findings"
          phx-click="open_tray_finding"
          phx-value-key={ruling.key}
          phx-target={@target}
          class="w-full flex items-start gap-2.5 px-2 py-2 rounded-lg text-left hover:bg-slate-200/50 dark:hover:bg-slate-700/40 cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500"
        >
          <span
            aria-hidden="true"
            class="mt-0.5 size-[18px] shrink-0 grid place-items-center rounded-full ring-1 ring-inset ring-slate-400 dark:ring-slate-500 text-slate-600 dark:text-slate-300"
          >
            <.icon name="pi-swap-bold" class="size-[11px]" />
          </span>
          <span class="min-w-0 flex-1">
            <span class="flex items-center gap-1.5 min-w-0 text-[10.5px] text-slate-500 dark:text-slate-400">
              <span class="shrink-0 font-semibold text-slate-600 dark:text-slate-300">Ruling changed</span>
              <span class="truncate">{ruling(ruling.now)}, was {ruling(ruling.was)}</span>
              <span class="ml-auto shrink-0 inline-flex items-center gap-1 px-2 py-0.5 text-[11px] font-semibold text-slate-500 dark:text-slate-400">
                Open<.icon name="pi-arrow-right" class="size-3" />
              </span>
            </span>
            <span class="block mt-0.5 text-[12.5px] leading-[18px] truncate text-slate-800 dark:text-slate-100">
              {ruling.title}
            </span>
          </span>
        </button>

        <div
          :for={{{kind, comment}, number} <- @comments}
          id={"review-tray-#{kind}-#{comment.id}"}
          data-qa="review_tray_comment"
          data-kind={kind}
          class="flex items-start gap-2.5 px-2 py-2 rounded-lg hover:bg-slate-200/50 dark:hover:bg-slate-700/40"
        >
          <span
            aria-hidden="true"
            class="mt-0.5 size-[18px] shrink-0 grid place-items-center rounded-full text-[10px] font-bold bg-amber-400 text-slate-900"
          >
            {number}
          </span>
          <div class="min-w-0 flex-1">
            <div class="flex items-center gap-1.5 min-w-0 text-[10.5px] text-slate-500 dark:text-slate-400">
              <span
                :if={kind == :finding}
                class="shrink-0 font-semibold text-slate-600 dark:text-slate-300"
              >
                Finding
              </span>
              <button
                :if={kind == :finding}
                type="button"
                title="Open in Findings"
                data-qa="review_tray_finding_comment"
                phx-click="open_tray_finding"
                phx-value-key={comment.finding.key}
                phx-target={@target}
                class="min-w-0 flex items-center gap-1.5 text-left hover:text-slate-900 dark:hover:text-slate-100 cursor-pointer rounded focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500"
              >
                <span class="min-w-0 truncate hover:underline">{comment.finding.title}</span>
                <span class="shrink-0">·</span>
                <span class="max-w-[45%] shrink-0 truncate">{comment.label}</span>
              </button>
              <span
                :if={kind == :diff}
                class="shrink-0 font-semibold text-slate-600 dark:text-slate-300"
              >
                Diff
              </span>
              <span
                :if={kind == :diff}
                class="truncate font-mono"
                title={"#{comment.path}:#{comment.line}"}
              >
                {line_place(comment)}
              </span>
              <span
                :if={kind == :screen}
                class="shrink-0 font-semibold text-slate-600 dark:text-slate-300"
              >
                Screen
              </span>
              <button
                :if={kind == :screen}
                type="button"
                title="Open the shot"
                data-qa="review_tray_screen"
                phx-click="open_tray_screen"
                phx-value-key={comment.key}
                phx-target={@target}
                class="min-w-0 truncate text-left hover:underline hover:text-slate-900 dark:hover:text-slate-100 cursor-pointer rounded focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500"
              >
                {comment.label}
              </button>
              <span :if={kind == :screen and comment.commit} class="shrink-0 font-mono">
                {String.slice(comment.commit, 0, 7)}
              </span>
              <button
                type="button"
                id={"remove-review-tray-#{kind}-#{comment.id}"}
                data-qa="remove_review_tray_comment"
                phx-click="remove_review_tray_comment"
                phx-value-kind={kind}
                phx-value-id={comment.id}
                phx-target={@target}
                class="ml-auto shrink-0 inline-flex items-center gap-1 px-2 py-0.5 rounded text-[11px] font-semibold text-slate-500 dark:text-slate-400 hover:text-slate-900 dark:hover:text-slate-100 hover:bg-slate-100 dark:hover:bg-slate-800 cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500"
              >
                <.icon name="pi-trash" class="size-[13px]" />Remove
              </button>
            </div>
            <p class="mt-0.5 text-[12.5px] leading-[18px] truncate text-slate-800 dark:text-slate-100">
              {comment.body}
            </p>
          </div>
        </div>
      </div>

      <div id="review-send-tray-hint" class={["px-4 pb-2.5", not @show_rows && "pt-1"]}>
        <span class="flex items-start gap-1.5 text-[11px] leading-4 text-slate-500 dark:text-slate-400 min-w-0">
          <span class={[
            "mt-[5px] size-1.5 shrink-0 rounded-full",
            @working && "bg-green-500 motion-safe:animate-pulse",
            not @working && "bg-slate-400"
          ]} />
          <span class="min-w-0 break-words">{@hint}</span>
        </span>
      </div>
    </div>
    """
  end

  # What the gate says, first match winning, and whether the lead is the reason.
  defp hint(gate, fix, comments, error) do
    cond do
      is_binary(error) -> {error, false}
      gate.working -> {"The Review lead is working. Send waits until it stops.", true}
      not gate.saved -> {"Send waits for the first round to finish.", false}
      gate.plan -> {plan_hint(fix ++ comments), false}
      fix == [] and comments == [] -> {empty_hint(gate), false}
      gate.finished -> {"The review is finished. Send reopens it with a fix round on your comments.", false}
      fix == [] -> {"Nothing to fix. Send starts a fix round on your comments.", false}
      true -> {"The Review lead is idle and starts a fix round on these at once.", false}
    end
  end

  defp plan_hint([]), do: @plan_unchanged
  defp plan_hint(_changes), do: "The fix plan is out of date. Send asks the lead to revise it."

  defp empty_hint(%{ci_failed: true}), do: "CI failed on the fix commit"

  defp empty_hint(%{undecided: count}) when count > 0,
    do:
      "Rule every finding before the review can finish: #{count} still #{if count == 1, do: "needs", else: "need"} a ruling."

  defp empty_hint(_gate), do: "Nothing to fix. Finish review closes the review."

  defp ruling(:fix), do: "Fix"
  defp ruling(:skip), do: "Don't fix"

  # A code finding's place reads by its file's name, its full path in the title.
  defp where(%Finding{kind: :code, file: file, line: line}) when is_binary(file) and is_integer(line),
    do: "#{Path.basename(file)}:#{line}"

  defp where(%Finding{} = finding), do: Finding.where(finding)

  defp line_place(%DiffComment{path: path, line: line}), do: "#{Path.basename(path)}:#{line}"
end
