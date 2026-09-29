defmodule RailWeb.Components.DiffRow do
  @moduledoc """
  One row of a diff: a hunk header, a line, a gap between hunks, or the notice
  that stands in for a binary file.

  A file in the diff pane and a finding's excerpt draw the same rows, and those
  lines have to read identically wherever they are shown.
  """
  use RailWeb, :html

  attr :row, :map, required: true
  attr :expanded, :any, default: nil, doc: "the lines of a gap the reader opened"
  attr :target, :any, default: nil

  def diff_row(%{row: %{kind: :binary}} = assigns) do
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

  def diff_row(%{row: %{kind: :hunk_header}} = assigns) do
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
  def diff_row(%{row: %{kind: :gap}, expanded: lines} = assigns) when is_list(lines) do
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

  def diff_row(%{row: %{kind: :gap}} = assigns) do
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

  def diff_row(%{row: %{kind: :line}} = assigns) do
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
end
