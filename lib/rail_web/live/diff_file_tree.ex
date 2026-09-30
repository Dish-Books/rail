defmodule RailWeb.Live.DiffFileTree do
  @moduledoc """
  The list of files beside the diff, a component of its own so that a mark or a
  selection patches the list and not every line of the pane.
  """
  use RailWeb, :live_component

  import RailWeb.Utils.DiffFileName
  import RailWeb.Utils.DiffStatusStyle

  # Enough of a directory to tell two files apart, cut from the front because the
  # end of a path is the part that says which file this is.
  @dir_limit 26

  @impl true
  def render(assigns) do
    ~H"""
    <div class="contents">
      <div
        :if={@show?}
        id="diff-file-tree"
        data-qa="diff-tree diff_file_tree"
        class="w-[248px] shrink-0 overflow-y-auto border-r border-slate-200 dark:border-slate-700 bg-slate-50 dark:bg-slate-800/30 p-2"
      >
        <p class="px-2 py-1.5 text-[10px] font-bold uppercase tracking-[0.12em] text-slate-500 dark:text-slate-400">
          {@label}
        </p>

        <button
          :for={row <- @rows}
          :key={row.id}
          type="button"
          phx-click="select_diff_file"
          phx-target={@target}
          phx-value-path={row.file.path}
          aria-current={to_string(row.selected?)}
          data-qa="diff-file-row"
          class={[
            "w-full flex items-start gap-2 px-2 py-1.5 rounded-lg text-left cursor-pointer",
            row.selected? && "bg-slate-200/70 dark:bg-slate-700/60",
            not row.selected? && "hover:bg-slate-200/50 dark:hover:bg-slate-700/40"
          ]}
        >
          <.file_mark viewed?={row.viewed?} status={row.file.status} />

          <span class="min-w-0 flex-1">
            <span class="flex items-center gap-1.5">
              <span class="truncate font-mono text-xs font-semibold text-slate-900 dark:text-slate-100">
                {diff_file_name(row.file).name}
              </span>
              <span
                :if={row.unsent > 0}
                data-qa="diff_file_unsent"
                title={unsent_title(row.unsent)}
                class="inline-flex items-center gap-0.5 shrink-0 font-mono text-[10px] font-bold text-amber-700 dark:text-amber-300"
              >
                <.icon name="pi-chat-text-fill" class="size-3" />{row.unsent}
              </span>
            </span>
            <span class="block truncate font-mono text-[10px] text-slate-500 dark:text-slate-400">
              {short_dir(diff_file_name(row.file).dir)}
            </span>
          </span>

          <span class="shrink-0 flex flex-col items-end gap-1">
            <.diff_stat additions={row.file.additions} deletions={row.file.deletions} font_size={10} />
            <.diff_bar additions={row.file.additions} deletions={row.file.deletions} />
          </span>
        </button>
      </div>
    </div>
    """
  end

  attr :viewed?, :boolean, required: true
  attr :status, :atom, required: true

  # Read is worth a mark of its own; until then the dot says what became of the
  # file, which is what tells two rows of the same name apart.
  defp file_mark(assigns) do
    ~H"""
    <.icon :if={@viewed?} name="pi-check-circle" class="mt-0.5 size-4 shrink-0 text-emerald-500" />
    <.icon
      :if={not @viewed?}
      name="pi-dot"
      class={["mt-0.5 size-4 shrink-0", diff_status_style(@status).color]}
    />
    """
  end

  attr :additions, :integer, required: true
  attr :deletions, :integer, required: true

  # The proportions at a glance, in the five squares every code host draws.
  defp diff_bar(assigns) do
    assigns = assign(assigns, :blocks, Enum.with_index(blocks(assigns.additions, assigns.deletions)))

    ~H"""
    <span data-qa="diff_bar" class="inline-flex gap-px">
      <span
        :for={{block, index} <- @blocks}
        data-qa={"diff_bar_#{block}"}
        class={[
          "size-1.5",
          index == 0 && "rounded-l-xs",
          index == 4 && "rounded-r-xs",
          block == :added && "bg-emerald-500",
          block == :deleted && "bg-rose-500",
          block == :neutral && "bg-slate-300 dark:bg-slate-600"
        ]}
      />
    </span>
    """
  end

  defp blocks(0, 0), do: List.duplicate(:neutral, 5)

  defp blocks(additions, deletions) do
    total = additions + deletions
    deleted = portion(deletions, total)
    added = min(portion(additions, total), 5 - deleted)

    List.duplicate(:added, added) ++
      List.duplicate(:deleted, deleted) ++ List.duplicate(:neutral, 5 - added - deleted)
  end

  defp portion(0, _total), do: 0
  defp portion(count, total), do: count |> Kernel.*(5) |> div(total) |> max(1) |> min(5)

  defp unsent_title(1), do: "1 unsent comment"
  defp unsent_title(unsent), do: "#{unsent} unsent comments"

  defp short_dir(nil), do: nil

  defp short_dir(dir) do
    dir = String.trim_trailing(dir, "/")

    if String.length(dir) > @dir_limit, do: "…" <> String.slice(dir, -@dir_limit, @dir_limit), else: dir
  end
end
