defmodule RailWeb.Components.DiffCommentList do
  @moduledoc """
  The comments the reader sees on the diff, listed beside it under Not sent, Sent
  and Resolved. A row jumps to its comment, and the reader's own sent ones can be
  resolved from here.
  """
  use RailWeb, :html

  attr :groups, :list,
    required: true,
    doc: "`%{status, label, rows}`, each row a comment, whether its line changed and whether the reader wrote it"

  attr :selected, :string, default: nil, doc: "the id of the comment last jumped to"
  attr :target, :any, required: true

  def diff_comment_list(assigns) do
    ~H"""
    <div id="diff-comment-list" data-qa="diff_comment_list">
      <p
        :if={@groups == []}
        class="px-2 py-1.5 text-xs text-slate-500 dark:text-slate-400"
      >
        Nobody has commented on this diff yet.
      </p>

      <div
        :for={group <- @groups}
        data-qa={"diff_comment_group_#{group.status}"}
        class="mt-2 first:mt-0"
      >
        <p class="px-2 py-1.5 text-[10px] font-bold uppercase tracking-[0.12em] text-slate-500 dark:text-slate-400">
          {group.label} <span class="font-mono">{length(group.rows)}</span>
        </p>

        <div
          :for={row <- group.rows}
          data-qa="diff_comment_list_row"
          aria-current={to_string(row.comment.id == @selected)}
          class={[
            "flex items-start gap-2 px-2 py-1.5 rounded-lg",
            row.comment.id == @selected && "bg-slate-200/70 dark:bg-slate-700/60",
            row.comment.id != @selected && "hover:bg-slate-200/50 dark:hover:bg-slate-700/40"
          ]}
        >
          <span
            :if={row.comment.status == :unsent}
            class="mt-0.5 size-3.5 shrink-0 grid place-items-center text-amber-600 dark:text-amber-400"
          >
            <.icon name="pi-chat-text-fill" class="size-3" />
          </span>
          <span
            :if={not row.mine? and row.comment.status == :sent}
            data-qa="diff_comment_list_mark"
            class="mt-0.5 size-3.5 shrink-0 grid place-items-center text-slate-500 dark:text-slate-400"
          >
            <.icon name="pi-paper-plane-tilt" class="size-3" />
          </span>
          <span
            :if={not row.mine? and row.comment.status == :resolved}
            data-qa="diff_comment_list_mark"
            class="mt-0.5 size-3.5 shrink-0 grid place-items-center text-emerald-600 dark:text-emerald-400"
          >
            <.icon name="pi-check-circle-fill" class="size-3.5" />
          </span>
          <button
            :if={row.mine? and row.comment.status != :unsent}
            type="button"
            role="checkbox"
            aria-checked={to_string(row.comment.status == :resolved)}
            aria-label="Resolved"
            phx-click="resolve_diff_comment"
            phx-value-id={row.comment.id}
            phx-value-resolved={to_string(row.comment.status == :sent)}
            phx-target={@target}
            data-qa="diff_comment_list_resolve"
            class={[
              "mt-0.5 size-3.5 shrink-0 grid place-items-center rounded border cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500",
              row.comment.status == :resolved && "border-emerald-500 bg-emerald-500 text-white",
              row.comment.status == :sent && "border-slate-400 dark:border-slate-500"
            ]}
          >
            <.icon :if={row.comment.status == :resolved} name="pi-check-bold" class="size-2.5" />
          </button>

          <button
            type="button"
            phx-click="select_diff_comment"
            phx-value-id={row.comment.id}
            phx-target={@target}
            data-qa="diff_comment_list_jump"
            class="min-w-0 flex-1 text-left cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500"
          >
            <span class="flex items-center gap-1.5 font-mono text-[10px] text-slate-500 dark:text-slate-400">
              <span class="shrink-0">{line_label(row.comment)}</span>
              <span
                :if={row.changed?}
                data-qa="diff_comment_list_changed"
                title="Line changed"
                class="shrink-0 inline-flex items-center gap-0.5 text-slate-500 dark:text-slate-400"
              >
                <.icon name="pi-arrows-clockwise-bold" class="size-2.5" />changed
              </span>
              <span
                :if={not row.mine?}
                data-qa="diff_comment_list_author"
                class="truncate max-w-20"
              >
                {author_name(row.comment)}
              </span>
              <span class="truncate">{Path.basename(row.comment.path)}</span>
            </span>
            <span class={[
              "text-[12px] leading-[17px] line-clamp-2 break-words",
              row.comment.status == :resolved && "text-slate-500 dark:text-slate-400",
              row.comment.status != :resolved && "text-slate-800 dark:text-slate-100"
            ]}>
              {row.comment.body}
            </span>
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp line_label(%{line_kind: :deleted, line: line}), do: "Removed line #{line}"
  defp line_label(%{line: line}), do: "Line #{line}"

  defp author_name(%{user: user}), do: user.name || user.login
end
