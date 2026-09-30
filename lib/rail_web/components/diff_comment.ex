defmodule RailWeb.Components.DiffComment do
  @moduledoc """
  One unsent comment on a line of the diff, as its author sees it.

  A comment lifted off its line quotes the line as it read when it was written,
  because that quote is what the engineer is sent.
  """
  use RailWeb, :html

  attr :comment, :map, required: true
  attr :target, :any, default: nil
  attr :lifted?, :boolean, default: false, doc: "drawn away from its line, so it quotes it"
  attr :changed?, :boolean, default: false, doc: "its line is drawn and reads differently now"

  def diff_comment(assigns) do
    ~H"""
    <div
      data-qa="diff_comment"
      class="max-w-[760px] rounded-r-lg border border-l-2 border-slate-200 dark:border-slate-700 border-l-amber-500 dark:border-l-amber-500 bg-white dark:bg-slate-900 px-3 py-1.5"
    >
      <div class="flex items-center gap-2 h-5">
        <span class="inline-flex items-center gap-1 text-[11px] font-semibold text-slate-500 dark:text-slate-400">
          <.icon name="pi-user" class="size-3" />You
        </span>
        <span class="inline-flex items-center rounded px-1.5 py-0.5 text-[10px] font-bold uppercase tracking-wider bg-amber-100 dark:bg-amber-950 text-amber-800 dark:text-amber-300">
          Not sent
        </span>
        <span
          :if={@changed?}
          data-qa="diff_comment_changed"
          class="inline-flex items-center gap-1 rounded px-1.5 py-0.5 text-[10px] font-bold uppercase tracking-wider bg-slate-200 dark:bg-slate-700 text-slate-700 dark:text-slate-200"
        >
          <.icon name="pi-arrows-clockwise-bold" class="size-3" />Line changed
        </span>
        <button
          type="button"
          phx-click="remove_diff_comment"
          phx-value-id={@comment.id}
          phx-target={@target}
          data-qa="diff_comment_remove"
          class="ml-auto inline-flex items-center gap-1 px-2 py-0.5 rounded text-[11px] font-semibold text-slate-500 dark:text-slate-400 hover:text-slate-900 dark:hover:text-slate-100 hover:bg-slate-100 dark:hover:bg-slate-800 cursor-pointer"
        >
          <.icon name="pi-trash" class="size-3.5" />Remove
        </button>
      </div>

      <p :if={@lifted?} class="mt-1 text-[11px] font-semibold text-slate-500 dark:text-slate-400">
        {quote_label(@comment)}
      </p>
      <div
        :if={@lifted?}
        data-qa="diff_comment_quote"
        class={[
          "mt-1 flex font-mono text-[11px] leading-5 rounded-sm overflow-hidden border-l-2",
          quote_tone(@comment.line_kind)
        ]}
      >
        <span class="w-4 shrink-0 text-center font-bold">{glyph(@comment.line_kind)}</span>
        <span class="whitespace-pre-wrap break-all pr-2 text-slate-700 dark:text-slate-200">{@comment.line_text}</span>
      </div>

      <p
        phx-no-format
        class={[
          "text-[13px] leading-[21px] text-slate-800 dark:text-slate-100 whitespace-pre-wrap break-words",
          @lifted? && "mt-1.5",
          not @lifted? && "mt-0.5"
        ]}
      >{@comment.body}</p>
    </div>
    """
  end

  defp quote_label(%{line_kind: :deleted, line: line}), do: "Removed line #{line} when you commented"
  defp quote_label(%{line: line}), do: "Line #{line} when you commented"

  defp quote_tone(:added), do: "border-emerald-500 bg-emerald-500/10 text-emerald-600 dark:text-emerald-500"
  defp quote_tone(:deleted), do: "border-rose-500 bg-rose-500/10 text-rose-600 dark:text-rose-500"
  defp quote_tone(:context), do: "border-slate-300 dark:border-slate-600 bg-slate-500/5 text-slate-400"

  defp glyph(:added), do: "+"
  defp glyph(:deleted), do: "-"
  defp glyph(:context), do: " "
end
