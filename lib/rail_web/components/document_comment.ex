defmodule RailWeb.Components.DocumentComment do
  @moduledoc """
  One of the reader's unsent comments on a line of the ticket or the plan, carrying its number in the tray. A comment
  whose line no longer reads as it did is drawn dashed and changed, quoting the line as it read when it was written.
  """
  use RailWeb, :html

  attr :comment, :map, required: true
  attr :number, :integer, required: true, doc: "its number in the tray"
  attr :named, :boolean, default: false, doc: "names its line, for a card not drawn directly under it"
  attr :lifted, :boolean, default: false, doc: "its line no longer reads as it did"
  attr :target, :any, required: true

  def document_comment(%{lifted: true} = assigns) do
    ~H"""
    <div
      id={"document-comment-#{@comment.id}"}
      data-qa="document_comment"
      data-lifted="true"
      class="rounded-lg border border-dashed border-slate-300 dark:border-slate-600 px-3 py-2"
    >
      <div class="flex items-center gap-2 min-w-0">
        <span
          aria-label={"Comment #{@number}"}
          class="size-[18px] shrink-0 grid place-items-center rounded-full border-[1.5px] border-dashed border-slate-500 text-slate-400 text-[10px] font-bold"
        >
          {@number}
        </span>
        <span
          data-qa="document_comment_changed"
          class="inline-flex items-center gap-1 rounded px-1.5 py-0.5 text-[10px] font-bold uppercase tracking-wider shrink-0 bg-slate-200 dark:bg-slate-700 text-slate-700 dark:text-slate-200"
        >
          <.icon name="pi-arrows-clockwise-bold" class="size-[11px]" />Changed
        </span>
        <span class="min-w-0 truncate font-mono text-[10.5px] text-slate-500 dark:text-slate-400">
          {@comment.element_label} as you commented on it
        </span>
        <.remove comment={@comment} target={@target} />
      </div>
      <blockquote
        phx-no-format
        data-qa="document_comment_quote"
        class="mt-1.5 ml-[26px] pl-2.5 border-l-2 border-slate-300 dark:border-slate-600 text-[12.5px] leading-[18px] text-slate-500 dark:text-slate-400 whitespace-pre-wrap wrap-anywhere"
      >{@comment.element_text}</blockquote>
      <p
        phx-no-format
        class="mt-1 ml-[26px] text-[12.5px] leading-[18px] text-slate-700 dark:text-slate-200 whitespace-pre-wrap wrap-anywhere"
      >{@comment.body}</p>
    </div>
    """
  end

  def document_comment(assigns) do
    ~H"""
    <div
      id={"document-comment-#{@comment.id}"}
      data-qa="document_comment"
      class="max-w-[760px] rounded-r-lg border border-l-2 border-slate-200 dark:border-slate-700 border-l-amber-500 dark:border-l-amber-500 bg-white dark:bg-slate-900 px-3 py-1.5"
    >
      <div class="flex flex-wrap items-center gap-x-2 gap-y-1 min-h-5 min-w-0">
        <span
          aria-label={"Comment #{@number}"}
          data-qa="document_comment_number"
          class="size-[18px] shrink-0 grid place-items-center rounded-full bg-amber-400 text-slate-900 text-[10px] font-bold"
        >
          {@number}
        </span>
        <span class="inline-flex items-center gap-1 text-[11px] font-semibold text-slate-500 dark:text-slate-400 shrink-0">
          <.icon name="pi-user" class="size-3" />You
        </span>
        <span class="inline-flex items-center rounded px-1.5 py-0.5 text-[10px] font-bold uppercase tracking-wider shrink-0 bg-amber-100 dark:bg-amber-950 text-amber-800 dark:text-amber-300">
          Not sent
        </span>
        <span
          :if={@named}
          data-qa="document_comment_line"
          class="min-w-0 truncate font-mono text-[11px] text-slate-500 dark:text-slate-400"
        >
          {name(@comment)}
        </span>
        <.remove comment={@comment} target={@target} />
      </div>
      <p
        phx-no-format
        class="mt-0.5 text-[13px] leading-[21px] text-slate-800 dark:text-slate-100 whitespace-pre-wrap wrap-anywhere"
      >{@comment.body}</p>
    </div>
    """
  end

  attr :comment, :map, required: true
  attr :target, :any, required: true

  defp remove(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="remove_plan_comment"
      phx-value-id={@comment.id}
      phx-target={@target}
      data-qa="document_comment_remove"
      class="ml-auto inline-flex items-center gap-1 px-2 py-0.5 rounded text-[11px] font-semibold text-slate-500 dark:text-slate-400 hover:text-slate-900 dark:hover:text-slate-100 hover:bg-slate-100 dark:hover:bg-slate-800 cursor-pointer shrink-0 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500"
    >
      <.icon name="pi-trash" class="size-3.5" />Remove
    </button>
    """
  end

  # Every node of a diagram has the same label, so the node is named by its id.
  defp name(%{element_kind: :node, element_text: id}), do: "Node #{id}"
  defp name(%{element_label: label}), do: label
end
