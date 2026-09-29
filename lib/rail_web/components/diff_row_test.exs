defmodule RailWeb.Components.DiffRowTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias RailWeb.Components.DiffRow

  test "draws a line as the kind of change it is" do
    html =
      render_component(&DiffRow.diff_row/1,
        row: %{kind: :line, line_kind: :deleted, old_line: 2, new_line: nil, text: "  def filter(list), do: list"}
      )

    assert html =~ ~s(data-kind="deleted")
    assert html =~ "def filter(list), do: list"
    refute html =~ "data-focus"
  end

  test "draws the highlighted code when the line came with any" do
    html =
      render_component(&DiffRow.diff_row/1,
        row: %{
          kind: :line,
          line_kind: :added,
          old_line: nil,
          new_line: 1,
          text: "def",
          html: ~s|<span class="l-keyword">def</span>|
        }
      )

    assert html =~ ~s(<span class="l-keyword">def</span>)
  end

  test "offers to expand the unchanged lines between two hunks" do
    gap = %{kind: :gap, path: "lib/filter.ex", gap_index: 0, start_line: 4, end_line: 39, old_start_line: 4, count: 36}

    html = render_component(&DiffRow.diff_row/1, row: gap, target: "2")

    assert html =~ "Expand 36 unchanged lines"
    assert html =~ ~s(phx-value-gap_index="0")
    assert html =~ ~s(phx-value-path="lib/filter.ex")
    assert html =~ ~s(phx-target="2")
  end

  test "draws the fetched lines in place of the gap once it is opened" do
    gap = %{kind: :gap, path: "lib/filter.ex", gap_index: 0, start_line: 4, end_line: 4, old_start_line: 3, count: 1}

    html = render_component(&DiffRow.diff_row/1, row: gap, expanded: [%{text: "  # in between", html: nil}])

    refute html =~ "diff_gap_row"
    assert html =~ "# in between"
    assert html =~ ~s(data-kind="context")
  end

  test "stands in for a binary file rather than drawing it" do
    assert render_component(&DiffRow.diff_row/1, row: %{kind: :binary}) =~ "Binary file not shown"
  end

  test "draws a hunk header as the line git wrote" do
    assert render_component(&DiffRow.diff_row/1, row: %{kind: :hunk_header, text: "@@ -1,3 +1,4 @@ def filter/2"}) =~
             "def filter/2"
  end
end
