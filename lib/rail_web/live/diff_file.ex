defmodule RailWeb.Live.DiffFile do
  @moduledoc """
  One file of the diff pane, a component of its own so that marking it reviewed
  or re-reading it patches this file and not every line of the pane. Its lines
  take comments unless the view is a merge's.
  """
  use RailWeb, :live_component

  import RailWeb.Utils.DiffFileName
  import RailWeb.Utils.DiffStatusStyle

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :file_name, diff_file_name(assigns.file))

    ~H"""
    <div
      id={"diff-file-#{slug(@id)}"}
      data-qa="diff_file_section"
      data-path={@file.path}
      data-comment-target={@target}
      phx-hook="DiffSection"
      class="first:mt-3 rounded-xl border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-900"
    >
      <div
        id={"diff-header-#{slug(@id)}"}
        data-qa="diff_file_header"
        class={[
          "sticky -top-px z-10 h-11 px-3 flex items-center gap-2 rounded-t-xl data-stuck:rounded-t-none",
          "bg-slate-100 dark:bg-slate-800 border-b border-slate-200 dark:border-slate-700",
          @collapsed? && "rounded-b-xl"
        ]}
      >
        <button
          type="button"
          phx-click="toggle_collapsed"
          phx-target={@target}
          phx-value-path={@file.path}
          data-qa="diff_collapse_toggle"
          aria-label={"Fold #{@file.display_path}"}
          aria-expanded={to_string(not @collapsed?)}
          class="size-5 shrink-0 grid place-items-center rounded text-slate-500 dark:text-slate-400 hover:text-slate-900 dark:hover:text-slate-100 cursor-pointer"
        >
          <.icon name={if @collapsed?, do: "pi-caret-right", else: "pi-caret-down"} class="size-3.5" />
        </button>

        <span class="min-w-0 flex font-mono text-xs">
          <span class="truncate text-slate-500 dark:text-slate-400">{@file_name.dir}</span>
          <span class="shrink-0 font-bold text-slate-900 dark:text-slate-100">{@file_name.name}</span>
        </span>

        <.status_badge status={@file.status} />

        <span class="ml-auto shrink-0 flex items-center gap-3">
          <span
            :if={@unsent > 0}
            data-qa="diff_file_unsent"
            class="inline-flex items-center gap-1 rounded-full bg-amber-100 dark:bg-amber-950 px-2 py-0.5 text-[11px] font-semibold text-amber-800 dark:text-amber-300"
          >
            <.icon name="pi-chat-text-fill" class="size-3" />{@unsent} unsent
          </span>

          <.diff_stat additions={@file.additions} deletions={@file.deletions} font_size={11} />

          <button
            type="button"
            phx-click="toggle_viewed"
            phx-target={@target}
            phx-value-path={@file.path}
            phx-value-digest={@file.digest}
            aria-pressed={to_string(@viewed?)}
            data-qa="diff-viewed-checkbox"
            class={[
              "inline-flex items-center gap-1.5 pl-1.5 pr-2.5 py-1 rounded-lg border text-xs font-semibold cursor-pointer",
              @viewed? &&
                "border-emerald-500/40 bg-emerald-500/10 text-emerald-700 dark:text-emerald-400",
              not @viewed? &&
                "border-slate-200 dark:border-slate-700 text-slate-500 dark:text-slate-400 hover:text-slate-900 dark:hover:text-slate-100"
            ]}
          >
            <span class={[
              "size-4 grid place-items-center rounded border",
              @viewed? && "border-emerald-500 bg-emerald-500 text-white",
              not @viewed? && "border-slate-300 dark:border-slate-600"
            ]}>
              <.icon :if={@viewed?} name="pi-check" class="size-3" />
            </span>
            Reviewed
          </button>
        </span>
      </div>

      <div :if={not @collapsed? and @lifted != []} data-qa="diff_comments_lifted">
        <div
          :if={@changed_count > 0}
          class="px-4 py-2 flex items-center gap-2 bg-amber-50 dark:bg-amber-950/40 border-b border-amber-200 dark:border-amber-900 text-[12px] text-amber-900 dark:text-amber-200"
        >
          <.icon name="pi-info" class="size-4" />
          <p>
            <b class="font-semibold">{changed_notice(@changed_count)}</b>
            {changed_detail(@changed_count)}
          </p>
        </div>

        <div class="px-4 py-2.5 space-y-2 bg-slate-50 dark:bg-slate-800/40 border-b border-slate-200 dark:border-slate-700">
          <.diff_comment
            :for={{comment, changed?} <- @lifted}
            comment={comment}
            target={@target}
            lifted?={true}
            changed?={changed?}
            open?={comment.id in @open}
            mine?={comment.user_id == @reader_id}
          />
        </div>
      </div>

      <div
        :if={not @collapsed?}
        style={"content-visibility: auto; contain-intrinsic-size: auto #{intrinsic_height(@segments)}px;"}
        class="diff-body rounded-b-xl"
      >
        <div class="diff-rows">
          <div :for={segment <- @segments} class="contents">
            <.diff_row
              :for={row <- segment.rows}
              row={row}
              expanded={expanded(@expanded_gaps, row)}
              target={@target}
              commentable={@commentable?}
            />
            <div :for={comment <- segment.comments} class="diff-comment-row">
              <.diff_comment
                comment={comment}
                target={@target}
                open?={comment.id in @open}
                mine?={comment.user_id == @reader_id}
              />
            </div>
            <.comment_composer :if={segment.draft} draft={segment.draft} target={@target} />
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :draft, :map, required: true
  attr :target, :any, required: true

  # Indented under the code column, so it reads as belonging to the line above.
  # Named for its line, so moving it mounts a new box that takes the focus, and two
  # files patched one after the other never both hold it.
  defp comment_composer(%{draft: draft} = assigns) do
    assigns = assign(assigns, :key, slug("#{draft.path}-#{draft.line_kind}-#{draft.line}"))

    ~H"""
    <div class="diff-comment-row">
      <.comment_box
        id={"diff-comment-form-#{@key}"}
        body_id={"diff-comment-body-#{@key}"}
        qa="diff_comment"
        label={"line #{@draft.line}"}
        body={@draft[:body]}
        submit="save_diff_comment"
        change="change_diff_comment"
        cancel="cancel_diff_comment"
        target={@target}
      />
    </div>
    """
  end

  attr :status, :atom, required: true

  # Modified is what a file in a diff is unless it says otherwise, and needs no
  # label of its own.
  defp status_badge(assigns) do
    assigns = assign(assigns, :style, diff_status_style(assigns.status))

    ~H"""
    <span
      :if={@style.label}
      data-qa="diff_status_badge"
      class={[
        "shrink-0 px-1.5 py-0.5 rounded text-[10px] font-bold uppercase tracking-wider",
        @style.color,
        @style.tint
      ]}
    >
      {@style.label}
    </span>
    """
  end

  defp expanded(expanded_gaps, %{kind: :gap, key: key}), do: Map.get(expanded_gaps, key)
  defp expanded(_expanded_gaps, _row), do: nil

  # A row each, at the height rows are drawn at. Only a guess for a file that has
  # not been rendered yet, which is all the browser wants.
  defp intrinsic_height(segments), do: Enum.sum_by(segments, &length(&1.rows)) * 22

  defp changed_notice(1), do: "1 comment is on a line that has changed."
  defp changed_notice(count), do: "#{count} comments are on lines that have changed."

  defp changed_detail(1), do: "It is still sent, quoting the line as you saw it."
  defp changed_detail(_count), do: "They are still sent, quoting the lines as you saw them."

  defp slug(id), do: id |> String.replace(~r/[^a-zA-Z0-9_-]/, "-") |> String.trim("-")
end
