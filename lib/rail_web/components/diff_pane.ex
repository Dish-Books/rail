defmodule RailWeb.Components.DiffPane do
  @moduledoc """
  Two-column Diff Pane component with a directory-trie file tree on the left
  and a virtualized-height diff row layout on the right.
  """
  use RailWeb, :html

  import RailWeb.Components.AppShell, only: [icon: 1]
  import RailWeb.Components.DiffStat, only: [diff_stat: 1]

  alias Rail.Domain.Diff.BinaryNoticeRow
  alias Rail.Domain.Diff.DiffRowModel
  alias Rail.Domain.Diff.FileDiff
  alias Rail.Domain.Diff.GapRow
  alias Rail.Domain.Diff.HunkHeaderRow
  alias Rail.Domain.Diff.LineRow

  attr :files, :list, default: []
  attr :viewed, :any, default: %{}
  attr :expanded_gaps, :map, default: %{}
  attr :selected_file, :string, default: nil
  attr :show_file_tree, :boolean, default: true
  attr :empty_message, :string, default: "Nothing has been changed on this branch yet."

  def diff_pane(assigns) do
    viewed = assigns[:viewed] || %{}
    files = assigns[:files] || []
    expanded_gaps = assigns[:expanded_gaps] || %{}

    assigns =
      assigns
      |> assign(:viewed, viewed)
      |> assign(:files, files)
      |> assign(:expanded_gaps, expanded_gaps)

    if Enum.empty?(files) do
      ~H"""
      <div
        id="diff-empty-state"
        data-qa="diff_empty_state"
        class="flex flex-col items-center justify-center min-h-[340px] text-center p-8 bg-[var(--color-surface)] rounded-xl border border-[var(--color-border)] shadow-xs"
      >
        <.icon name="hero-check-circle" class="w-12 h-12 text-emerald-600 mb-3" />
        <p class="text-sm font-medium text-[var(--color-on-surface)]">
          {@empty_message}
        </p>
      </div>
      """
    else
      layout = DiffRowModel.build_rows(files, viewed, expanded_gaps)
      tree_items = build_flattened_tree(files)

      assigns =
        assigns
        |> assign(:layout, layout)
        |> assign(:tree_items, tree_items)

      ~H"""
      <div id="diff-pane" data-qa="diff-pane diff_pane" class="flex gap-3 min-h-[400px]">
        <%= if @show_file_tree do %>
          <!-- Left: 280px File Tree -->
          <div
            id="diff-file-tree"
            data-qa="diff-tree diff_file_tree"
            class="w-[280px] shrink-0 bg-[var(--color-surface)] rounded-xl border border-[var(--color-border)] p-2 overflow-y-auto max-h-[750px]"
          >
            <div class="space-y-0.5">
              <%= for item <- @tree_items do %>
                <%= if item.type == :dir do %>
                  <div
                    class="flex items-center gap-1.5 py-1 pr-3 text-xs font-semibold text-[var(--color-on-surface-variant)] select-none truncate"
                    style={"padding-left: #{12 + item.depth * 14}px;"}
                  >
                    <.icon name="hero-folder" class="w-4 h-4 shrink-0 text-[var(--color-outline)]" />
                    <span class="truncate">{item.name}</span>
                  </div>
                <% else %>
                  <button
                    type="button"
                    phx-click="select_diff_file"
                    phx-value-path={item.file.path}
                    data-qa="diff-file-row"
                    class={[
                      "w-full flex items-center justify-between gap-1.5 py-1.5 pr-3 text-xs text-left rounded-lg transition-colors cursor-pointer select-none",
                      if(@selected_file == item.file.path,
                        do: "bg-[var(--color-primary-container)]/35 text-[var(--color-on-surface)]",
                        else:
                          "hover:bg-[var(--color-surface-container-high)] text-[var(--color-on-surface-variant)]"
                      )
                    ]}
                    style={"padding-left: #{12 + item.depth * 14}px;"}
                  >
                    <div class="flex items-center gap-1.5 truncate min-w-0">
                      <%= if file_viewed?(@viewed, item.file.path) do %>
                        <.icon name="hero-check-circle" class="w-4 h-4 shrink-0 text-emerald-600" />
                      <% else %>
                        <.icon
                          name="hero-document-text"
                          class="w-4 h-4 shrink-0 text-[var(--color-outline)]"
                        />
                      <% end %>
                      <span class={[
                        "truncate",
                        @selected_file == item.file.path && "font-bold text-[var(--color-on-surface)]"
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
                <% end %>
              <% end %>
            </div>
          </div>
        <% end %>

        <!-- Right: Diff Row List -->
        <div
          id="diff-row-list"
          data-qa="diff_row_list"
          class="flex-1 min-w-0 bg-[var(--color-surface)] rounded-xl border border-[var(--color-border)] overflow-hidden flex flex-col max-h-[750px]"
        >
          <div
            class="overflow-x-auto overflow-y-auto flex-1 selection:bg-blue-500/20"
            phx-hook="DiffHighlight"
            id="diff-highlight-scroller"
          >
            <%= for section <- @layout.sections do %>
              <div
                id={"diff-file-#{slugify(section.file.path)}"}
                data-qa="diff_file_section"
                class="border-b border-[var(--color-border)] last:border-b-0"
              >
                <!-- File Header Row (40px) -->
                <div
                  id={"diff-header-#{slugify(section.file.path)}"}
                  data-qa="diff_file_header"
                  class="sticky top-0 z-10 h-10 px-4 flex items-center justify-between gap-3 bg-[var(--color-surface-container-high)] border-b border-[var(--color-border)]/30"
                >
                  <div class="flex items-center gap-2 truncate min-w-0">
                    <%= if section.header.is_viewed do %>
                      <.icon name="hero-check-circle" class="w-4 h-4 shrink-0 text-emerald-600" />
                    <% else %>
                      <.icon
                        name="hero-document-text"
                        class="w-4 h-4 shrink-0 text-[var(--color-outline)]"
                      />
                    <% end %>
                    <span class="font-mono text-xs font-bold text-[var(--color-on-surface)] truncate">
                      {display_path(section.file)}
                    </span>
                  </div>

                  <div class="flex items-center gap-4 shrink-0">
                    <.diff_stat
                      additions={section.file.additions}
                      deletions={section.file.deletions}
                      font_size={11}
                    />

                    <label class="inline-flex items-center gap-1.5 cursor-pointer select-none">
                      <input
                        type="checkbox"
                        checked={section.header.is_viewed}
                        phx-click="toggle_viewed"
                        phx-value-path={section.file.path}
                        phx-value-digest={section.file.digest}
                        data-qa="diff-viewed-checkbox"
                        class="rounded border-[var(--color-border)] text-[var(--color-primary)] focus:ring-[var(--color-primary)] cursor-pointer"
                      />
                      <span class="text-xs font-medium text-[var(--color-on-surface)]">Viewed</span>
                    </label>
                  </div>
                </div>

                <!-- Body Rows: Collapsed if viewed -->
                <%= unless section.header.is_viewed do %>
                  <div class="divide-y divide-transparent">
                    <%= for row <- section.body_rows do %>
                      {render_row(row)}
                    <% end %>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>
        </div>
      </div>
      """
    end
  end

  @doc false
  def build_flattened_tree(files) when is_list(files) do
    tree =
      Enum.reduce(files, %{}, fn file, acc ->
        segments = Path.split(file.path)
        insert_into_tree(acc, segments, file)
      end)

    flatten_tree_node(tree, 0)
  end

  defp render_row(%BinaryNoticeRow{} = _row) do
    assigns = %{}

    ~H"""
    <div
      data-qa="diff_binary_notice"
      class="h-9 px-4 flex items-center gap-2 bg-[var(--color-surface)] text-[var(--color-outline)]"
    >
      <.icon name="hero-information-circle" class="w-4 h-4 shrink-0 text-[var(--color-outline)]" />
      <span class="text-xs italic">Binary file not shown</span>
    </div>
    """
  end

  defp render_row(%GapRow{} = row) do
    assigns = %{row: row}

    ~H"""
    <button
      type="button"
      phx-click="expand_gap"
      phx-value-path={@row.file.path}
      phx-value-gap-index={@row.gap_index}
      phx-value-start-line={@row.start_line}
      phx-value-end-line={@row.end_line}
      data-qa="diff_gap_row"
      class="w-full h-7 px-4 flex items-center justify-center gap-1.5 bg-[var(--color-surface-container)] hover:bg-[var(--color-surface-container-high)] text-[var(--color-primary)] transition-colors cursor-pointer select-none text-xs"
    >
      <.icon name="hero-arrows-up-down" class="w-3.5 h-3.5 shrink-0" />
      <span class="text-[11px] font-medium">Expand {@row.count} hidden lines</span>
    </button>
    """
  end

  defp render_row(%HunkHeaderRow{} = row) do
    assigns = %{row: row, text: hunk_header_text(row.hunk)}

    ~H"""
    <div
      data-qa="diff_hunk_header"
      class="h-7 px-4 flex items-center bg-[var(--color-surface-container-high)] font-mono text-[11px] text-[var(--color-on-surface-variant)] truncate select-none border-y border-[var(--color-border)]/20"
    >
      <span class="truncate">{@text}</span>
    </div>
    """
  end

  defp render_row(%LineRow{} = row) do
    {bg_class, glyph_class, glyph} =
      case row.line.kind do
        :added -> {"bg-[#262ea043] text-emerald-400", "text-emerald-500", "+"}
        :deleted -> {"bg-[#26f85149] text-rose-400", "text-rose-500", "-"}
        :context -> {"bg-transparent text-[var(--color-on-surface)]", "text-[var(--color-outline)]", " "}
      end

    assigns = %{
      row: row,
      bg_class: bg_class,
      glyph_class: glyph_class,
      glyph: glyph
    }

    ~H"""
    <div
      data-qa="diff_line_row"
      data-kind={@row.line.kind}
      class={["h-[22px] flex items-stretch leading-[22px] font-mono text-xs select-text", @bg_class]}
    >
      <!-- Gutter: Old line number (44px) -->
      <div class="w-11 min-w-[44px] shrink-0 pr-1.5 text-right font-mono text-[11px] text-[var(--color-outline)] bg-[var(--color-surface-container)] select-none tabular-nums">
        {@row.line.old_line_number || ""}
      </div>

      <!-- Gutter: New line number (44px) -->
      <div class="w-11 min-w-[44px] shrink-0 pr-1.5 text-right font-mono text-[11px] text-[var(--color-outline)] bg-[var(--color-surface-container)] select-none tabular-nums">
        {@row.line.new_line_number || ""}
      </div>

      <!-- Glyph (22px) -->
      <div class={[
        "w-[22px] min-w-[22px] shrink-0 flex items-center justify-center font-mono text-xs font-bold select-none",
        @glyph_class
      ]}>
        {@glyph}
      </div>

      <!-- Code Text -->
      <div class="flex-1 min-w-0 pl-1.5 whitespace-pre overflow-visible">
        {@row.line.text}
      </div>
    </div>
    """
  end

  defp hunk_header_text(%{section_heading: heading, header: header}) when is_binary(heading) and heading != "" do
    "#{header}  #{heading}"
  end

  defp hunk_header_text(%{header: header}), do: header

  defp display_path(%FileDiff{} = file) do
    if file.is_renamed and is_binary(file.old_path) and is_binary(file.new_path) and file.old_path != "" and
         file.new_path != "" do
      "#{file.old_path} → #{file.new_path}"
    else
      file.path
    end
  end

  defp slugify(path) do
    path
    |> String.replace(~r/[^a-zA-Z0-9_-]/, "-")
    |> String.trim("-")
  end

  defp file_viewed?(viewed, path) do
    Map.has_key?(viewed, path)
  end

  defp insert_into_tree(acc, [_filename], file) do
    files = Map.get(acc, :__files__, [])
    Map.put(acc, :__files__, [file | files])
  end

  defp insert_into_tree(acc, [dir | rest], file) do
    sub_tree = Map.get(acc, dir, %{})
    Map.put(acc, dir, insert_into_tree(sub_tree, rest, file))
  end

  defp flatten_tree_node(node, depth) do
    dir_keys =
      node
      |> Map.keys()
      |> Enum.reject(&(&1 == :__files__))
      |> Enum.sort()

    dir_items =
      Enum.flat_map(dir_keys, fn dir_name ->
        sub_node = Map.get(node, dir_name)
        dir_header = %{type: :dir, name: dir_name, depth: depth}
        [dir_header | flatten_tree_node(sub_node, depth + 1)]
      end)

    files =
      node
      |> Map.get(:__files__, [])
      |> Enum.sort_by(& &1.path)
      |> Enum.map(fn file ->
        %{type: :file, name: Path.basename(file.path), file: file, depth: depth}
      end)

    dir_items ++ files
  end
end
