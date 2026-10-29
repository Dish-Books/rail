defmodule RailWeb.Components.CommentList do
  @moduledoc """
  The task page's Comments item: how many comments the reader sees and their order, then a row for each with who
  left it, when, what it was on, a Not sent or Resolved tag and its words. A row opens where it was left, which its
  label names.
  """
  use RailWeb, :html

  attr :comments, :list, required: true, doc: "entries from `Rail.Pipeline.list_comments/2`, in the order shown"
  attr :order, :string, required: true, doc: ~s("newest" or "oldest")
  attr :screen_keys, :any, required: true, doc: "the keys of the screen states that have a shot now"
  attr :reader_id, :string, required: true
  attr :target, :any, required: true

  def comment_list(assigns) do
    ~H"""
    <div id="comments-pane" data-qa="comments_pane" class="flex-1 min-w-0 min-h-0 flex flex-col">
      <div
        id="comments-toolbar"
        class="shrink-0 flex items-center gap-3 px-6 py-3 border-b border-slate-200 dark:border-slate-700"
      >
        <h2 class="text-sm font-bold text-slate-900 dark:text-slate-100">Comments</h2>
        <span data-qa="comments_count" class="text-xs text-slate-500 dark:text-slate-400">
          {length(@comments)}
        </span>
        <.segmented_control
          id="comment-order"
          options={[{"newest", "Newest first"}, {"oldest", "Oldest first"}]}
          selected={@order}
          event="order_comments"
          value_name="order"
          target={@target}
          aria-label="Order"
          class="ml-auto"
        />
      </div>

      <div
        :if={@comments == []}
        id="comments-empty"
        class="flex-1 flex flex-col items-center text-center max-w-md mx-auto px-6 py-20"
      >
        <div class="flex items-center justify-center size-14 rounded-2xl bg-slate-100 dark:bg-slate-800 text-slate-400 ring-1 ring-slate-200 dark:ring-slate-700">
          <.icon name="pi-chats" class="size-7" />
        </div>
        <h2 class="mt-5 text-base font-semibold text-slate-900 dark:text-slate-100">
          No comments yet
        </h2>
        <p class="mt-2 text-sm leading-relaxed text-slate-500 dark:text-slate-400">
          Messages to an agent and comments on the plan, diff, screens and findings appear here.
        </p>
      </div>

      <div :if={@comments != []} class="flex-1 min-h-0 overflow-y-auto px-4 py-3">
        <ol id="comment-list" class="max-w-[1100px] space-y-1">
          <li :for={entry <- @comments}>
            <button
              type="button"
              id={"comment-#{entry.id}"}
              data-qa="comment_row"
              phx-click="open_comment"
              phx-value-kind={entry.kind}
              phx-value-id={entry.id}
              phx-target={@target}
              class={[
                "group w-full text-left flex items-start gap-3 px-4 py-3 rounded-lg border-l-2 cursor-pointer hover:bg-slate-100 dark:hover:bg-slate-800/60 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500",
                if(unsent?(entry), do: "border-l-amber-500", else: "border-l-transparent")
              ]}
            >
              <span class="sr-only">{opens(entry, @screen_keys)}:</span>
              <span class="block min-w-0 flex-1">
                <span class="flex items-center gap-x-2.5 gap-y-1 min-w-0 flex-wrap">
                  <span
                    data-qa="comment_author"
                    class="text-[13px] font-semibold text-slate-900 dark:text-slate-100 min-w-0 max-w-[20rem] truncate"
                  >
                    {author(entry, @reader_id)}
                  </span>
                  <.local_time
                    id={"comment-#{entry.id}-at"}
                    at={entry.at}
                    class="text-[12px] text-slate-500 dark:text-slate-400 shrink-0"
                  />
                  <span class="text-slate-300 dark:text-slate-600" aria-hidden="true">·</span>
                  <span class="min-w-0 max-w-[44rem] flex">
                    <span class="inline-flex items-center gap-1.5 min-w-0 text-[12px]">
                      <.place entry={entry} />
                    </span>
                  </span>
                  <span
                    :if={unsent?(entry)}
                    data-qa="comment_unsent"
                    class="inline-flex items-center rounded px-1.5 py-0.5 text-[10px] font-bold uppercase tracking-wider shrink-0 bg-amber-100 dark:bg-amber-950 text-amber-800 dark:text-amber-300"
                  >
                    Not sent
                  </span>
                  <span
                    :if={resolved?(entry)}
                    data-qa="comment_resolved"
                    class="inline-flex items-center gap-1 rounded px-1.5 py-0.5 text-[10px] font-bold uppercase tracking-wider shrink-0 ring-1 ring-inset ring-emerald-300 dark:ring-emerald-800 text-emerald-700 dark:text-emerald-300"
                  >
                    <.icon name="pi-check-bold" class="size-3" />Resolved
                  </span>
                  <span
                    :if={shot_gone?(entry, @screen_keys)}
                    data-qa="comment_shot_gone"
                    class="inline-flex items-center gap-1 text-[11px] text-slate-500 dark:text-slate-400 shrink-0"
                  >
                    <.icon name="pi-image-broken" class="size-3.5" />No shot of this screen now
                  </span>
                </span>
                <span
                  data-qa="comment_body"
                  class="mt-1 block text-[14px] leading-relaxed text-slate-700 dark:text-slate-200 max-w-[72ch] whitespace-pre-line wrap-anywhere"
                >{entry.comment.body}</span>
              </span>
              <span
                data-qa="comment_opens"
                aria-hidden="true"
                class="shrink-0 inline-flex items-center gap-1.5 px-2.5 py-1 rounded-lg ring-1 ring-inset ring-slate-300 dark:ring-slate-600 text-[12px] font-semibold text-slate-700 dark:text-slate-200 group-hover:bg-slate-200 dark:group-hover:bg-slate-700 group-hover:ring-slate-400 dark:group-hover:ring-slate-500"
              >
                {opens(entry, @screen_keys)}<.icon name="pi-arrow-up-right" class="size-3.5" />
              </span>
            </button>
          </li>
        </ol>
      </div>
    </div>
    """
  end

  defp place(%{entry: %{kind: :diff, comment: comment}} = assigns) do
    assigns = assign(assigns, :where, "#{comment.path}:#{comment.line}")

    ~H"""
    <.on icon="pi-git-diff" what="Diff" detail={@where} mono />
    """
  end

  defp place(%{entry: %{kind: :message}} = assigns) do
    ~H"""
    <.icon name="pi-chat-circle-text" class="size-3.5 text-slate-500 dark:text-slate-400" />
    <span class="font-semibold text-slate-700 dark:text-slate-200 truncate">
      {@entry.comment.role.name}
    </span>
    <span class="shrink-0 text-slate-500 dark:text-slate-400">conversation</span>
    """
  end

  defp place(%{entry: %{kind: :screen}} = assigns) do
    ~H"""
    <.on icon="pi-image" what="Screen" detail={@entry.comment.label} />
    """
  end

  defp place(%{entry: %{kind: :finding, comment: comment}} = assigns) do
    assigns = assign(assigns, :detail, "#{comment.finding.key} · #{comment.label}")

    ~H"""
    <.on icon="pi-list-checks" what="Finding" detail={@detail} />
    """
  end

  defp place(%{entry: %{kind: :plan, comment: %{target: :design} = comment}} = assigns) do
    element = if comment.element_text == "", do: "<#{comment.element_tag}>", else: ~s("#{comment.element_text}")
    assigns = assign(assigns, :detail, "#{comment.option_key} · #{element}")

    ~H"""
    <.on icon="pi-paint-brush" what="Design" detail={@detail} />
    """
  end

  defp place(%{entry: %{kind: :plan, comment: %{target: :ticket}}} = assigns) do
    ~H"""
    <.on icon="pi-ticket" what="Ticket" detail={@entry.comment.element_label} />
    """
  end

  defp place(%{entry: %{kind: :plan, comment: %{target: :plan}}} = assigns) do
    ~H"""
    <.on icon="pi-clipboard-text" what="Plan" detail={@entry.comment.element_label} />
    """
  end

  defp place(%{entry: %{kind: :plan, comment: %{target: :fix_plan}}} = assigns) do
    ~H"""
    <.on icon="pi-clipboard-text" what="Next round's plan" detail={@entry.comment.element_label} />
    """
  end

  # A row written before comments named their stage has none, so it reads as the output it is on.
  defp place(%{entry: %{kind: :plan, comment: %{target: :output} = comment}} = assigns) do
    assigns = assign(assigns, :what, comment.custom_stage || "Output")

    ~H"""
    <.on icon="pi-puzzle-piece" what={@what} detail={@entry.comment.element_label} />
    """
  end

  attr :icon, :string, required: true
  attr :what, :string, required: true
  attr :detail, :string, required: true
  attr :mono, :boolean, default: false

  defp on(assigns) do
    ~H"""
    <.icon name={@icon} class="size-3.5 text-slate-500 dark:text-slate-400" />
    <span class="shrink-0 font-semibold text-slate-700 dark:text-slate-200">{@what}</span>
    <span
      class={["truncate text-slate-600 dark:text-slate-300", @mono && "font-mono"]}
      title={@detail}
    >
      {@detail}
    </span>
    """
  end

  defp author(%{user: %{id: id}}, id), do: "You"
  defp author(%{user: %{} = user}, _reader_id), do: user.name || user.login
  # A message whose sender has since been removed.
  defp author(%{user: nil}, _reader_id), do: "Someone"

  defp opens(%{kind: :message}, _screen_keys), do: "Open the conversation"
  defp opens(%{kind: :diff}, _screen_keys), do: "Open in Diff"

  defp opens(%{kind: :screen} = entry, screen_keys),
    do: if(shot_gone?(entry, screen_keys), do: "Open Screens", else: "Open the screen")

  defp opens(%{kind: :finding}, _screen_keys), do: "Open the finding"

  defp opens(%{kind: :plan, comment: %{target: :output, custom_stage: name}}, _screen_keys),
    do: if(is_binary(name), do: "Open in #{name}", else: "Open its stage")

  defp opens(%{kind: :plan}, _screen_keys), do: "Open in Plan"

  defp unsent?(%{comment: %{status: :unsent}}), do: true
  defp unsent?(_sent_or_message), do: false

  defp resolved?(%{kind: :diff, comment: %{status: :resolved}}), do: true
  defp resolved?(_entry), do: false

  defp shot_gone?(%{kind: :screen, comment: %{key: key}}, screen_keys), do: key not in screen_keys
  defp shot_gone?(_entry, _screen_keys), do: false
end
