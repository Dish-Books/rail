defmodule RailWeb.Components.DiffPane do
  @moduledoc """
  The diff, as a file tree beside the changes themselves.

  Everything it draws comes out of `Rail.Git.load_diff/3` ready to render, so
  this decides nothing about the diff. Every event it raises goes to `@target`,
  so the stage owning the diff decides what selecting, expanding and marking read
  actually do.
  """
  use RailWeb, :html

  attr :files, :list, default: []
  attr :expanded_gaps, :map, default: %{}
  attr :selected_file, :string, default: nil
  attr :show_file_tree, :boolean, default: true
  attr :empty_message, :string, default: "Nothing has been changed on this branch yet."
  attr :target, :any, default: nil

  def diff_pane(assigns) do
    assigns = assign(assigns, :tree, tree(assigns.files))

    ~H"""
    <div
      :if={@files == []}
      id="diff-empty-state"
      data-qa="diff_empty_state"
      class="flex flex-col items-center justify-center min-h-[340px] text-center p-8 bg-white dark:bg-slate-900 rounded-xl border border-slate-200 dark:border-slate-700 shadow-xs"
    >
      <.icon name="pi-check-circle" class="w-12 h-12 text-emerald-600 mb-3" />
      <p class="text-sm font-medium text-slate-900 dark:text-slate-100">{@empty_message}</p>
    </div>

    <div
      :if={@files != []}
      id="diff-pane"
      data-qa="diff-pane diff_pane"
      class="flex gap-3 min-h-[400px]"
    >
      <div
        :if={@show_file_tree}
        id="diff-file-tree"
        data-qa="diff-tree diff_file_tree"
        class="w-[280px] shrink-0 bg-white dark:bg-slate-900 rounded-xl border border-slate-200 dark:border-slate-700 p-2 overflow-y-auto max-h-[750px]"
      >
        <div class="space-y-0.5">
          <div
            :for={item <- @tree}
            :if={item.type == :dir}
            class="flex items-center gap-1.5 py-1 pr-3 text-xs font-semibold text-slate-600 dark:text-slate-300 select-none truncate"
            style={"padding-left: #{12 + item.depth * 14}px;"}
          >
            <.icon name="pi-folder" class="w-4 h-4 shrink-0 text-slate-500 dark:text-slate-400" />
            <span class="truncate">{item.name}</span>
          </div>

          <button
            :for={item <- @tree}
            :if={item.type == :file}
            type="button"
            phx-click="select_diff_file"
            phx-target={@target}
            phx-value-path={item.file.path}
            data-qa="diff-file-row"
            class={[
              "w-full flex items-center justify-between gap-1.5 py-1.5 pr-3 text-xs text-left rounded-lg transition-colors cursor-pointer select-none",
              @selected_file == item.file.path &&
                "bg-blue-100 dark:bg-blue-900/35 text-slate-900 dark:text-slate-100",
              @selected_file != item.file.path &&
                "hover:bg-slate-100 dark:hover:bg-slate-700 text-slate-600 dark:text-slate-300"
            ]}
            style={"padding-left: #{12 + item.depth * 14}px;"}
          >
            <div class="flex items-center gap-1.5 truncate min-w-0">
              <.file_icon viewed?={item.file.viewed?} />
              <span class={[
                "truncate",
                @selected_file == item.file.path && "font-bold text-slate-900 dark:text-slate-100"
              ]}>
                {item.name}
              </span>
            </div>

            <.diff_stat
              additions={item.file.additions}
              deletions={item.file.deletions}
              font_size={10}
            />
          </button>
        </div>
      </div>

      <div
        id="diff-row-list"
        data-qa="diff_row_list"
        class="flex-1 min-w-0 bg-white dark:bg-slate-900 rounded-xl border border-slate-200 dark:border-slate-700 overflow-hidden flex flex-col max-h-[750px]"
      >
        <div
          class="overflow-x-auto overflow-y-auto flex-1 selection:bg-blue-500/20"
          phx-hook="DiffHighlight"
          id="diff-highlight-scroller"
        >
          <div
            :for={file <- @files}
            id={"diff-file-#{slug(file.path)}"}
            data-qa="diff_file_section"
            class="border-b border-slate-200 dark:border-slate-700 last:border-b-0"
          >
            <div
              id={"diff-header-#{slug(file.path)}"}
              data-qa="diff_file_header"
              class="sticky top-0 z-10 h-10 px-4 flex items-center justify-between gap-3 bg-slate-100 dark:bg-slate-700 border-b border-slate-200 dark:border-slate-700/30"
            >
              <div class="flex items-center gap-2 truncate min-w-0">
                <.file_icon viewed?={file.viewed?} />
                <span class="font-mono text-xs font-bold text-slate-900 dark:text-slate-100 truncate">
                  {file.display_path}
                </span>
              </div>

              <div class="flex items-center gap-4 shrink-0">
                <.diff_stat additions={file.additions} deletions={file.deletions} font_size={11} />

                <label class="inline-flex items-center gap-1.5 cursor-pointer select-none">
                  <input
                    type="checkbox"
                    checked={file.viewed?}
                    phx-click="toggle_viewed"
                    phx-target={@target}
                    phx-value-path={file.path}
                    phx-value-digest={file.digest}
                    data-qa="diff-viewed-checkbox"
                    class="rounded border-slate-200 dark:border-slate-700 text-blue-600 dark:text-blue-500 focus:ring-blue-600 dark:focus:ring-blue-500 cursor-pointer"
                  />
                  <span class="text-xs font-medium text-slate-900 dark:text-slate-100">Viewed</span>
                </label>
              </div>
            </div>

            <div :if={not file.viewed?} class="divide-y divide-transparent">
              <.row
                :for={row <- file.rows}
                row={row}
                expanded={expanded(@expanded_gaps, row)}
                target={@target}
              />
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :viewed?, :boolean, required: true

  defp file_icon(assigns) do
    ~H"""
    <.icon
      :if={@viewed?}
      name="pi-check-circle"
      class="w-4 h-4 shrink-0 text-emerald-600"
    />
    <.icon
      :if={not @viewed?}
      name="pi-file-text"
      class="w-4 h-4 shrink-0 text-slate-500 dark:text-slate-400"
    />
    """
  end

  attr :row, :map, required: true
  attr :expanded, :any, default: nil
  attr :target, :any, default: nil

  defp row(%{row: %{kind: :binary}} = assigns) do
    ~H"""
    <div
      data-qa="diff_binary_notice"
      class="h-9 px-4 flex items-center gap-2 bg-white dark:bg-slate-900 text-slate-500 dark:text-slate-400"
    >
      <.icon name="pi-info" class="w-4 h-4 shrink-0 text-slate-500 dark:text-slate-400" />
      <span class="text-xs italic">Binary file not shown</span>
    </div>
    """
  end

  defp row(%{row: %{kind: :hunk_header}} = assigns) do
    ~H"""
    <div
      data-qa="diff_hunk_header"
      class="h-7 px-4 flex items-center bg-slate-100 dark:bg-slate-700 font-mono text-[11px] text-slate-600 dark:text-slate-300 truncate select-none border-y border-slate-200 dark:border-slate-700/20"
    >
      <span class="truncate">{@row.text}</span>
    </div>
    """
  end

  # A gap the reader has opened is the lines themselves; one they have not is the
  # offer to fetch them.
  defp row(%{row: %{kind: :gap}, expanded: lines} = assigns) when is_list(lines) do
    assigns = assign(assigns, :lines, Enum.with_index(lines))

    ~H"""
    <.line
      :for={{text, offset} <- @lines}
      line={
        %{
          line_kind: :context,
          old_line: @row.old_start_line + offset,
          new_line: @row.start_line + offset,
          text: text
        }
      }
    />
    """
  end

  defp row(%{row: %{kind: :gap}} = assigns) do
    ~H"""
    <button
      type="button"
      phx-click="expand_gap"
      phx-target={@target}
      phx-value-path={@row.path}
      phx-value-gap_index={@row.gap_index}
      phx-value-start_line={@row.start_line}
      phx-value-end_line={@row.end_line}
      data-qa="diff_gap_row"
      class="w-full h-7 px-4 flex items-center justify-center gap-1.5 bg-slate-50 dark:bg-slate-800 hover:bg-slate-100 dark:hover:bg-slate-700 text-blue-600 dark:text-blue-500 transition-colors cursor-pointer select-none text-xs"
    >
      <.icon name="pi-arrows-down-up" class="w-3.5 h-3.5 shrink-0" />
      <span class="text-[11px] font-medium">Expand {@row.count} hidden lines</span>
    </button>
    """
  end

  defp row(%{row: %{kind: :line}} = assigns) do
    ~H"""
    <.line line={@row} />
    """
  end

  attr :line, :map, required: true

  defp line(assigns) do
    assigns = assign(assigns, :style, line_style(assigns.line.line_kind))

    ~H"""
    <div
      data-qa="diff_line_row"
      data-kind={@line.line_kind}
      class={[
        "h-[22px] flex items-stretch leading-[22px] font-mono text-xs select-text",
        @style.background
      ]}
    >
      <div class="w-11 min-w-[44px] shrink-0 pr-1.5 text-right font-mono text-[11px] text-slate-500 dark:text-slate-400 bg-slate-50 dark:bg-slate-800 select-none tabular-nums">
        {@line.old_line}
      </div>

      <div class="w-11 min-w-[44px] shrink-0 pr-1.5 text-right font-mono text-[11px] text-slate-500 dark:text-slate-400 bg-slate-50 dark:bg-slate-800 select-none tabular-nums">
        {@line.new_line}
      </div>

      <div class={[
        "w-[22px] min-w-[22px] shrink-0 flex items-center justify-center font-mono text-xs font-bold select-none",
        @style.glyph_class
      ]}>
        {@style.glyph}
      </div>

      <div class="flex-1 min-w-0 pl-1.5 whitespace-pre overflow-visible">{@line.text}</div>
    </div>
    """
  end

  defp line_style(:added),
    do: %{background: "bg-[#262ea043] text-emerald-400", glyph_class: "text-emerald-500", glyph: "+"}

  defp line_style(:deleted), do: %{background: "bg-[#26f85149] text-rose-400", glyph_class: "text-rose-500", glyph: "-"}

  defp line_style(:context),
    do: %{
      background: "bg-transparent text-slate-900 dark:text-slate-100",
      glyph_class: "text-slate-500 dark:text-slate-400",
      glyph: " "
    }

  defp expanded(expanded_gaps, %{kind: :gap, key: key}), do: Map.get(expanded_gaps, key)
  defp expanded(_expanded_gaps, _row), do: nil

  defp slug(path), do: path |> String.replace(~r/[^a-zA-Z0-9_-]/, "-") |> String.trim("-")

  # The files as a directory trie, flattened back out so the tree draws as one
  # list of indented rows.
  defp tree(files) do
    files
    |> Enum.reduce(%{}, fn file, acc -> insert(acc, Path.split(file.path), file) end)
    |> flatten(0)
  end

  defp insert(node, [_filename], file), do: Map.update(node, :__files__, [file], &[file | &1])

  defp insert(node, [dir | rest], file) do
    Map.put(node, dir, insert(Map.get(node, dir, %{}), rest, file))
  end

  defp flatten(node, depth) do
    directories =
      node
      |> Map.keys()
      |> Enum.reject(&(&1 == :__files__))
      |> Enum.sort()
      |> Enum.flat_map(fn name ->
        [%{type: :dir, name: name, depth: depth} | flatten(Map.get(node, name), depth + 1)]
      end)

    files =
      node
      |> Map.get(:__files__, [])
      |> Enum.sort_by(& &1.path)
      |> Enum.map(&%{type: :file, name: Path.basename(&1.path), file: &1, depth: depth})

    directories ++ files
  end
end
