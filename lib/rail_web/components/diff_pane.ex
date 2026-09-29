defmodule RailWeb.Components.DiffPane do
  @moduledoc """
  The diff, as a toolbar over a file list beside the changes themselves.

  Everything it draws comes out of `Rail.Git.load_diff/4` ready to render, so
  this decides nothing about the diff. Every event it raises goes to `@target`,
  so the stage owning the diff decides what selecting, expanding, filtering and
  marking read actually do. The one thing it works out for itself is which files
  the reader's query leaves visible, because the counts in the toolbar are of the
  whole diff either way.

  The toolbar, the file list and each file are live components of their own,
  because the browser redraws everything under whatever a patch touches. What
  `calculate_pane/1` returns is split the same way, so the stage can send a part
  that moved to that part alone.
  """
  use RailWeb, :html

  alias RailWeb.Live.DiffFile
  alias RailWeb.Live.DiffFileTree
  alias RailWeb.Live.DiffToolbar

  # Enough of a directory to tell two files apart, cut from the front because the
  # end of a path is the part that says which file this is.
  @dir_limit 26

  attr :files, :list, default: []
  attr :expanded_gaps, :map, default: %{}
  attr :collapsed, :list, default: []
  attr :selected_file, :string, default: nil
  attr :show_file_tree, :boolean, default: true
  attr :filter, :atom, default: :branch
  attr :query, :string, default: ""
  attr :empty_message, :string, default: "Nothing has been changed on this branch yet."
  attr :scroll_to, :string, default: nil
  attr :target, :any, default: nil

  def diff_pane(assigns) do
    assigns = assign(assigns, :pane, calculate_pane(assigns))

    ~H"""
    <div id="diff-pane" data-qa="diff-pane diff_pane" class="flex flex-col h-full">
      <.live_component module={DiffToolbar} id="diff-toolbar" {@pane.toolbar} />

      <div
        :if={@pane.frame.empty_message}
        id="diff-empty-state"
        data-qa="diff_empty_state"
        class="flex-1 flex flex-col items-center justify-center text-center p-8"
      >
        <.icon name="pi-check-circle" class="w-12 h-12 text-emerald-600 mb-3" />
        <p class="text-sm font-medium text-slate-900 dark:text-slate-100">
          {@pane.frame.empty_message}
        </p>
      </div>

      <div :if={@pane.tree} class="flex-1 min-h-0 flex">
        <.live_component module={DiffFileTree} id="diff-file-tree" {@pane.tree} />

        <div
          id="diff-row-list"
          data-qa="diff_row_list"
          class="flex-1 min-w-0 flex flex-col bg-slate-50 dark:bg-slate-800/30"
        >
          <%!-- A reader arriving from a finding is arriving at one file, so the
          scroller is told which section to put in front of them. --%>
          <div
            class="flex-1 overflow-y-auto px-3 pb-3 space-y-3 selection:bg-blue-500/20"
            phx-hook="DiffScroller"
            id="diff-scroller"
            data-scroll-to={@pane.frame.scroll_to}
          >
            <p
              :if={@pane.frame.no_match}
              data-qa="diff_no_match"
              class="py-10 text-center text-sm text-slate-500 dark:text-slate-400"
            >
              No file here matches {@pane.frame.no_match}.
            </p>

            <.live_component
              :for={{id, section} <- @pane.sections}
              :key={id}
              module={DiffFile}
              id={id}
              {section}
            />
          </div>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  What each part of the pane draws for the given pane assigns: the frame, which
  only changes when files come or go, then the toolbar, the file list and each
  file, keyed by the id its live component goes by.
  """
  def calculate_pane(assigns) do
    %{files: files, query: query, target: target, collapsed: collapsed, expanded_gaps: expanded_gaps} = assigns
    visible = Enum.filter(files, &matches?(&1, query))

    shared =
      for {path, count} <- Enum.frequencies_by(files, & &1.path), count > 1 or path == "", into: MapSet.new(), do: path

    %{
      frame: %{
        sections: Enum.map(visible, &section_id(&1, shared)),
        empty_message: if(files == [], do: assigns.empty_message),
        no_match: if(files != [] and visible == [], do: query),
        scroll_to: assigns.scroll_to
      },
      toolbar: %{
        target: target,
        show_file_tree: assigns.show_file_tree,
        filter: assigns.filter,
        query: query,
        additions: Enum.sum_by(files, & &1.additions),
        deletions: Enum.sum_by(files, & &1.deletions),
        viewed: Enum.count(files, & &1.viewed?),
        total: length(files)
      },
      tree:
        if(files != [],
          do: %{
            target: target,
            show?: assigns.show_file_tree,
            label: files_changed(files),
            rows: Enum.map(visible, &tree_row(&1, shared, assigns.selected_file))
          }
        ),
      sections:
        Enum.map(visible, fn file ->
          gap_keys = for %{kind: :gap, key: key} <- file.rows, do: key

          {section_id(file, shared),
           %{
             target: target,
             file: Map.drop(file, [:rows, :viewed?]),
             rows: file.rows,
             viewed?: file.viewed?,
             collapsed?: file.path in collapsed,
             expanded_gaps: Map.take(expanded_gaps, gap_keys)
           }}
        end)
    }
  end

  attr :target, :any, required: true
  attr :show_file_tree, :boolean, required: true
  attr :filter, :atom, required: true
  attr :query, :string, required: true
  attr :additions, :integer, required: true
  attr :deletions, :integer, required: true
  attr :viewed, :integer, required: true
  attr :total, :integer, required: true

  @doc """
  The pane's toolbar, as `RailWeb.Live.DiffToolbar` draws it.
  """
  def diff_toolbar(assigns) do
    ~H"""
    <div
      id="diff-toolbar"
      data-qa="diff_toolbar"
      class="h-12 shrink-0 flex items-center gap-3 px-3 border-b border-slate-200 dark:border-slate-700"
    >
      <button
        type="button"
        id="diff-toggle-files"
        data-qa="diff_toggle_files"
        phx-click="toggle_file_list"
        phx-target={@target}
        aria-pressed={to_string(@show_file_tree)}
        title="Show or hide the file list"
        class="size-8 shrink-0 grid place-items-center rounded-lg border border-slate-200 dark:border-slate-700 text-slate-500 dark:text-slate-400 hover:text-slate-900 dark:hover:text-slate-100 cursor-pointer"
      >
        <.icon name="pi-list" class="size-4" />
      </button>

      <.segmented_control
        id="diff-filter"
        data-qa="diff_filter"
        class="shrink-0"
        options={[branch: "All changes", uncommitted: "Uncommitted"]}
        selected={@filter}
        event="select_diff_filter"
        target={@target}
        value_name="filter"
        option_qa="diff_filter_option"
      />

      <.diff_stat additions={@additions} deletions={@deletions} class="shrink-0" />

      <div
        id="diff-viewed-progress"
        data-qa="diff_viewed_progress"
        class="shrink-0 flex items-center gap-2"
        title="Files you have marked read"
      >
        <div class="h-1.5 w-16 rounded-full bg-slate-200 dark:bg-slate-700 overflow-hidden">
          <div class="h-full rounded-full bg-emerald-500" style={"width: #{read(@total, @viewed)}%;"} />
        </div>
        <span class="font-mono text-[11px] tabular-nums text-slate-500 dark:text-slate-400">
          {@viewed}/{@total}
        </span>
      </div>

      <form
        id="diff-file-filter"
        phx-change="filter_diff_files"
        phx-target={@target}
        class="flex-1 min-w-0 flex items-center gap-2"
      >
        <.icon name="pi-magnifying-glass" class="size-3.5 text-slate-400 dark:text-slate-500" />
        <input
          type="text"
          name="query"
          value={@query}
          placeholder="Filter"
          autocomplete="off"
          phx-debounce="150"
          id="diff-file-query"
          data-qa="diff_file_query"
          class="w-full bg-transparent border-0 p-0 text-xs text-slate-900 dark:text-slate-100 placeholder:text-slate-400 dark:placeholder:text-slate-500 focus:ring-0"
        />
      </form>
    </div>
    """
  end

  attr :target, :any, required: true
  attr :show?, :boolean, required: true
  attr :label, :string, required: true
  attr :rows, :list, required: true

  @doc """
  The list of files beside the diff, as `RailWeb.Live.DiffFileTree` draws it.
  """
  def diff_file_tree(assigns) do
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
            <span class="block truncate font-mono text-xs font-semibold text-slate-900 dark:text-slate-100">
              {basename(row.file)}
            </span>
            <span class="block truncate font-mono text-[10px] text-slate-500 dark:text-slate-400">
              {short_dir(dirname(row.file))}
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

  attr :id, :string, required: true
  attr :target, :any, required: true
  attr :file, :map, required: true
  attr :rows, :list, required: true
  attr :viewed?, :boolean, required: true
  attr :collapsed?, :boolean, required: true
  attr :expanded_gaps, :map, required: true

  @doc """
  One file's header and lines, as `RailWeb.Live.DiffFile` draws it.
  """
  def diff_file(assigns) do
    ~H"""
    <div
      id={"diff-file-#{slug(@id)}"}
      data-qa="diff_file_section"
      data-path={@file.path}
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
          <span class="truncate text-slate-500 dark:text-slate-400">{dirname(@file)}</span>
          <span class="shrink-0 font-bold text-slate-900 dark:text-slate-100">{basename(@file)}</span>
        </span>

        <.status_badge status={@file.status} />

        <span class="ml-auto shrink-0 flex items-center gap-3">
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

      <div
        :if={not @collapsed?}
        style={"content-visibility: auto; contain-intrinsic-size: auto #{intrinsic_height(@rows)}px;"}
        class="overflow-x-auto rounded-b-xl"
      >
        <div class="min-w-max">
          <.row
            :for={row <- @rows}
            row={row}
            expanded={expanded(@expanded_gaps, row)}
            target={@target}
          />
        </div>
      </div>
    </div>
    """
  end

  attr :viewed?, :boolean, required: true
  attr :status, :atom, required: true

  # Read is worth a mark of its own; until then the dot says what became of the
  # file, which is what tells two rows of the same name apart.
  attr :rows, :list, required: true

  @doc """
  One hunk's rows, drawn the way the pane draws them.

  What a finding points at is a few lines of a change rather than a file, and
  those lines have to read identically wherever they are shown, so the pane lends
  them out rather than letting a second copy of them drift.
  """
  def diff_hunk(assigns) do
    ~H"""
    <div data-qa="diff_hunk" class="overflow-x-auto">
      <div class="min-w-max">
        <.row :for={row <- @rows} row={row} expanded={nil} target={nil} />
      </div>
    </div>
    """
  end

  defp file_mark(assigns) do
    ~H"""
    <.icon :if={@viewed?} name="pi-check-circle" class="mt-0.5 size-4 shrink-0 text-emerald-500" />
    <.icon
      :if={not @viewed?}
      name="pi-dot"
      class={["mt-0.5 size-4 shrink-0", status_color(@status)]}
    />
    """
  end

  attr :status, :atom, required: true

  # Modified is what a file in a diff is unless it says otherwise, and needs no
  # label of its own.
  defp status_badge(assigns) do
    ~H"""
    <span
      :if={@status != :modified}
      data-qa="diff_status_badge"
      class={[
        "shrink-0 px-1.5 py-0.5 rounded text-[10px] font-bold uppercase tracking-wider",
        status_color(@status),
        status_tint(@status)
      ]}
    >
      {status_label(@status)}
    </span>
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

  attr :row, :map, required: true
  attr :expanded, :any, default: nil
  attr :target, :any, default: nil

  defp row(%{row: %{kind: :binary}} = assigns) do
    ~H"""
    <div
      data-qa="diff_binary_notice"
      class="h-9 px-4 flex items-center gap-2 text-slate-500 dark:text-slate-400"
    >
      <.icon name="pi-info" class="w-4 h-4 shrink-0" />
      <span class="text-xs italic">Binary file not shown</span>
    </div>
    """
  end

  defp row(%{row: %{kind: :hunk_header}} = assigns) do
    ~H"""
    <div
      data-qa="diff_hunk_header"
      class="h-7 w-full flex items-center whitespace-nowrap font-mono text-[11px] text-slate-500 dark:text-slate-400 select-none bg-slate-100 dark:bg-slate-800 border-y border-slate-200 dark:border-slate-700/50"
    >
      <span class="sticky left-0 px-4 bg-slate-100 dark:bg-slate-800">{@row.text}</span>
    </div>
    """
  end

  # A gap the reader has opened is the lines themselves; one they have not is the
  # offer to fetch them.
  defp row(%{row: %{kind: :gap}, expanded: lines} = assigns) when is_list(lines) do
    assigns = assign(assigns, :lines, Enum.with_index(lines))

    ~H"""
    <.line
      :for={{line, offset} <- @lines}
      line={
        %{
          line_kind: :context,
          old_line: @row.old_start_line + offset,
          new_line: @row.start_line + offset,
          text: line.text,
          html: line.html
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
      class="w-full h-8 flex items-center gap-2 whitespace-nowrap bg-slate-50 dark:bg-slate-800/40 hover:bg-slate-100 dark:hover:bg-slate-800 text-slate-500 dark:text-slate-400 hover:text-slate-900 dark:hover:text-slate-100 cursor-pointer select-none"
    >
      <span class="w-[104px] shrink-0 flex justify-center">
        <span class="grid place-items-center size-5 rounded border border-slate-200 dark:border-slate-700">
          <.icon name="pi-arrows-down-up" class="size-3" />
        </span>
      </span>
      <span class="text-[11px] font-medium">Expand {@row.count} unchanged lines</span>
    </button>
    """
  end

  defp row(%{row: %{kind: :line}} = assigns) do
    ~H"""
    <.line line={@row} />
    """
  end

  attr :line, :map, required: true

  # The styling is `assets/css/diff.css`'s, keyed off these attributes, because a
  # large branch draws thousands of lines and each would otherwise carry it all.
  defp line(assigns) do
    ~H"""
    <%!-- A row fetched because something points at it says so: a reader arriving
    from a finding should not have to count lines to find the one it meant. --%>
    <div
      data-qa="diff_line_row"
      data-kind={@line.line_kind}
      data-focus={Map.get(@line, :focus?, false)}
      class="diff-line"
    >
      <div class="diff-num">{@line.old_line}</div>
      <div class="diff-num">{@line.new_line}</div>
      <div class="diff-glyph">{glyph(@line.line_kind)}</div>
      <%!-- A flex row drops the whitespace between its children, which a `pre` cell
      would otherwise draw as the blank lines the markup is written across. --%>
      <div class="diff-code">
        <.code text={@line.text} html={Map.get(@line, :html)} />
      </div>
    </div>
    """
  end

  attr :text, :string, required: true
  attr :html, :string, default: nil

  # Highlighting is allowed to fail, so the plain text is always the fallback and
  # is escaped by being drawn rather than injected.
  defp code(assigns) do
    ~H"""
    <span :if={@html} class="whitespace-pre">{raw(@html)}</span>
    <span :if={is_nil(@html)} class="whitespace-pre">{@text}</span>
    """
  end

  defp glyph(:added), do: "+"
  defp glyph(:deleted), do: "-"
  defp glyph(:context), do: " "

  defp read(0, _viewed), do: 0
  defp read(total, viewed), do: div(viewed * 100, total)

  defp files_changed([_one]), do: "1 file changed"
  defp files_changed(files), do: "#{length(files)} files changed"

  defp status_label(:added), do: "new file"
  defp status_label(status), do: status

  defp status_color(:added), do: "text-emerald-500"
  defp status_color(:deleted), do: "text-rose-500"
  defp status_color(:renamed), do: "text-violet-500"
  defp status_color(_modified), do: "text-amber-500"

  defp status_tint(:added), do: "bg-emerald-500/10"
  defp status_tint(:deleted), do: "bg-rose-500/10"
  defp status_tint(_renamed), do: "bg-violet-500/10"

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

  defp matches?(_file, ""), do: true
  defp matches?(file, query), do: String.contains?(String.downcase(file.path), String.downcase(query))

  # A rename is the whole point of its own row, so it stays one piece.
  defp basename(%{display_path: display_path}) do
    if renamed?(display_path), do: display_path, else: Path.basename(display_path)
  end

  defp dirname(%{display_path: display_path}) do
    cond do
      renamed?(display_path) -> nil
      Path.dirname(display_path) == "." -> nil
      true -> Path.dirname(display_path) <> "/"
    end
  end

  defp renamed?(display_path), do: String.contains?(display_path, " → ")

  defp short_dir(nil), do: nil

  defp short_dir(dir) do
    dir = String.trim_trailing(dir, "/")

    if String.length(dir) > @dir_limit, do: "…" <> String.slice(dir, -@dir_limit, @dir_limit), else: dir
  end

  defp expanded(expanded_gaps, %{kind: :gap, key: key}), do: Map.get(expanded_gaps, key)
  defp expanded(_expanded_gaps, _row), do: nil

  # A row each, at the height rows are drawn at. Only a guess for a file that has
  # not been rendered yet, which is all the browser wants.
  defp intrinsic_height(rows), do: length(rows) * 22

  # A path keeps naming a file while its contents change, so its part is patched
  # rather than replaced. A path that is not one file's alone takes the digest:
  # a file that changed type is two blocks, and one that would not parse has none.
  defp section_id(%{path: path, digest: digest}, shared) do
    if MapSet.member?(shared, path), do: digest, else: path
  end

  defp tree_row(file, shared, selected_file) do
    %{
      id: section_id(file, shared),
      file: Map.drop(file, [:rows, :viewed?]),
      viewed?: file.viewed?,
      selected?: file.path == selected_file
    }
  end

  defp slug(path), do: path |> String.replace(~r/[^a-zA-Z0-9_-]/, "-") |> String.trim("-")
end
