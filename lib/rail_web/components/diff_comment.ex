defmodule RailWeb.Components.DiffComment do
  @moduledoc """
  One comment on a line of the diff: unsent, sending while Send is on its way, sent,
  or resolved and folded to one line until the reader opens it. Only its author can
  remove, resolve or unresolve it.

  A comment lifted off its line quotes the line as it read when it was written,
  because that quote is what the engineer is sent.
  """
  use RailWeb, :html

  attr :comment, :map, required: true
  attr :target, :any, default: nil
  attr :lifted?, :boolean, default: false, doc: "drawn away from its line, so it quotes it"
  attr :changed?, :boolean, default: false, doc: "its line is drawn and reads differently now"
  attr :open?, :boolean, default: false, doc: "a resolved comment the reader has unfolded"
  attr :mine?, :boolean, required: true, doc: "the reader wrote it"

  def diff_comment(%{comment: %{status: :resolved}, open?: false} = assigns) do
    assigns = assign(assigns, :author, if(assigns.mine?, do: "You", else: author_name(assigns.comment)))

    ~H"""
    <button
      type="button"
      id={"diff-comment-#{@comment.id}"}
      data-qa="diff_comment"
      phx-click="toggle_diff_comment"
      phx-value-id={@comment.id}
      phx-target={@target}
      aria-expanded="false"
      class="w-full max-w-[760px] h-8 flex items-center gap-2 px-2 rounded-r-lg border border-l-2 border-slate-200 dark:border-slate-700 border-l-emerald-500 dark:border-l-emerald-500 bg-white dark:bg-slate-900 hover:bg-slate-50 dark:hover:bg-slate-800/60 text-left cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500"
    >
      <.icon name="pi-caret-right" class="size-3.5 text-slate-500 dark:text-slate-400" />
      <span class="inline-flex items-center gap-1 text-[11px] font-bold uppercase tracking-wider text-emerald-700 dark:text-emerald-400 shrink-0">
        <.icon name="pi-check-circle-fill" class="size-3.5" />Resolved
      </span>
      <span
        data-qa="diff_comment_author"
        class="shrink-0 max-w-[40%] truncate text-[11px] font-semibold text-slate-500 dark:text-slate-400"
      >
        {@author}
      </span>
      <span class="min-w-0 flex-1 truncate text-[12px] text-slate-500 dark:text-slate-400">
        {@comment.body}
      </span>
      <span
        :if={@changed?}
        data-qa="diff_comment_changed"
        class="shrink-0 inline-flex items-center gap-1 text-[11px] text-slate-500 dark:text-slate-400"
      >
        <.icon name="pi-arrows-clockwise-bold" class="size-3" />Line changed
      </span>
    </button>
    """
  end

  def diff_comment(assigns) do
    author = if assigns.mine?, do: "You", else: author_name(assigns.comment)
    assigns = assigns |> assign(:author, author) |> assign(:quoted_by, if(assigns.mine?, do: "you", else: author))

    ~H"""
    <div
      id={"diff-comment-#{@comment.id}"}
      data-qa="diff_comment"
      class={[
        "max-w-[760px] rounded-r-lg border border-l-2 border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-900 px-3 py-1.5",
        @comment.status == :unsent && "border-l-amber-500 dark:border-l-amber-500",
        @comment.status == :sent && "border-l-slate-400 dark:border-l-slate-500",
        @comment.status == :resolved && "border-l-emerald-500 dark:border-l-emerald-500"
      ]}
    >
      <div class="flex flex-wrap items-center gap-x-2 gap-y-1 min-h-5 min-w-0">
        <button
          :if={@comment.status == :resolved}
          type="button"
          phx-click="toggle_diff_comment"
          phx-value-id={@comment.id}
          phx-target={@target}
          aria-expanded="true"
          aria-label="Fold comment"
          data-qa="diff_comment_fold"
          class="-ml-1 size-5 grid place-items-center rounded text-slate-500 dark:text-slate-400 hover:text-slate-900 dark:hover:text-slate-100 cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500"
        >
          <.icon name="pi-caret-down" class="size-3.5" />
        </button>
        <span class="inline-flex items-center gap-1 text-[11px] font-semibold text-slate-500 dark:text-slate-400 shrink-0">
          <.icon name="pi-user" class="size-3" />{@author}
        </span>
        <span
          :if={@comment.status == :unsent}
          data-qa="diff_comment_unsent"
          class="inline-flex group-[.phx-click-loading]/diff:hidden items-center gap-1 rounded px-1.5 py-0.5 text-[10px] font-bold uppercase tracking-wider shrink-0 bg-amber-100 dark:bg-amber-950 text-amber-800 dark:text-amber-300"
        >
          Not sent
        </span>
        <%!-- Shown from the click on Send until its reply redraws the comment as Sent. --%>
        <span
          :if={@comment.status == :unsent}
          data-qa="diff_comment_sending"
          class="hidden group-[.phx-click-loading]/diff:inline-flex items-center gap-1 rounded px-1.5 py-0.5 text-[10px] font-bold uppercase tracking-wider shrink-0 ring-1 ring-inset ring-slate-300 dark:ring-slate-600 text-slate-600 dark:text-slate-300"
        >
          <.icon name="pi-circle-notch-bold" class="size-3 motion-safe:animate-spin" />Sending
        </span>
        <span
          :if={@comment.status == :sent}
          class="inline-flex items-center gap-1 rounded px-1.5 py-0.5 text-[10px] font-bold uppercase tracking-wider shrink-0 ring-1 ring-inset ring-slate-300 dark:ring-slate-600 text-slate-600 dark:text-slate-300"
        >
          <.icon name="pi-paper-plane-tilt-bold" class="size-3" />Sent
        </span>
        <span
          :if={@comment.status == :resolved}
          class="inline-flex items-center gap-1 rounded px-1.5 py-0.5 text-[10px] font-bold uppercase tracking-wider shrink-0 bg-emerald-100 dark:bg-emerald-950 text-emerald-800 dark:text-emerald-300"
        >
          <.icon name="pi-check-bold" class="size-3" />Resolved
        </span>
        <span
          :if={@changed?}
          data-qa="diff_comment_changed"
          class="inline-flex items-center gap-1 rounded px-1.5 py-0.5 text-[10px] font-bold uppercase tracking-wider shrink-0 bg-slate-200 dark:bg-slate-700 text-slate-700 dark:text-slate-200"
        >
          <.icon name="pi-arrows-clockwise-bold" class="size-3" />Line changed
        </span>
        <button
          :if={@comment.status == :unsent}
          type="button"
          phx-click="remove_diff_comment"
          phx-value-id={@comment.id}
          phx-target={@target}
          data-qa="diff_comment_remove"
          class={action_class()}
        >
          <.icon name="pi-trash" class="size-3.5" />Remove
        </button>
        <button
          :if={@mine? and @comment.status == :sent}
          type="button"
          phx-click="resolve_diff_comment"
          phx-value-id={@comment.id}
          phx-value-resolved="true"
          phx-target={@target}
          data-qa="diff_comment_resolve"
          class={action_class()}
        >
          <.icon name="pi-check-circle" class="size-3.5" />Resolve
        </button>
        <button
          :if={@mine? and @comment.status == :resolved}
          type="button"
          phx-click="resolve_diff_comment"
          phx-value-id={@comment.id}
          phx-value-resolved="false"
          phx-target={@target}
          data-qa="diff_comment_unresolve"
          class={action_class()}
        >
          <.icon name="pi-arrow-counter-clockwise" class="size-3.5" />Unresolve
        </button>
      </div>

      <p :if={@lifted?} class="mt-1 text-[11px] font-semibold text-slate-500 dark:text-slate-400">
        {quote_label(@comment)} when {@quoted_by} commented
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

  defp action_class do
    "ml-auto inline-flex items-center gap-1 px-2 py-0.5 rounded text-[11px] font-semibold text-slate-500 dark:text-slate-400 hover:text-slate-900 dark:hover:text-slate-100 hover:bg-slate-100 dark:hover:bg-slate-800 cursor-pointer shrink-0 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500"
  end

  defp quote_label(%{line_kind: :deleted, line: line}), do: "Removed line #{line}"
  defp quote_label(%{line: line}), do: "Line #{line}"

  defp author_name(%{user: user}), do: user.name || user.login

  defp quote_tone(:added), do: "border-emerald-500 bg-emerald-500/10 text-emerald-600 dark:text-emerald-500"
  defp quote_tone(:deleted), do: "border-rose-500 bg-rose-500/10 text-rose-600 dark:text-rose-500"
  defp quote_tone(:context), do: "border-slate-300 dark:border-slate-600 bg-slate-500/5 text-slate-400"

  defp glyph(:added), do: "+"
  defp glyph(:deleted), do: "-"
  defp glyph(:context), do: " "
end
