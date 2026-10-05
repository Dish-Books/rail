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

  test "offers a comment on a line of the diff only when asked to" do
    row = %{kind: :line, line_kind: :added, old_line: nil, new_line: 4, text: "x = 1"}

    assert render_component(&DiffRow.diff_row/1, row: row, commentable: true) =~ ~s(data-qa="diff_comment_add")
    refute render_component(&DiffRow.diff_row/1, row: row) =~ "diff_comment_add"
  end

  # An opened gap is fetched on demand and gone after a reload, so a comment on
  # it would never find its line again.
  test "offers no comment on a line of an opened gap" do
    gap = %{kind: :gap, path: "lib/filter.ex", gap_index: 0, start_line: 4, end_line: 4, old_start_line: 3, count: 1}

    refute render_component(&DiffRow.diff_row/1,
             row: gap,
             expanded: [%{text: "  # in between", html: nil}],
             commentable: true
           ) =~
             "diff_comment_add"
  end

  # Wrapped rows hang four columns past the indent, tabs being four wide, and by whole
  # tab stops on a line with a tab; a hang of four is the stylesheet's default.
  test "a line carries how far its wrapped rows hang, in columns" do
    for {text, hang} <- [
          {"    x = 1", ["--hang: 8ch"]},
          {"\tx = 1", ["--hang: 8ch"]},
          {"\t\tx", ["--hang: 12ch"]},
          {"  \t  x", ["--hang: 12ch"]},
          {"x\t= 1", []},
          {"x = 1", []}
        ] do
      html =
        (&DiffRow.diff_row/1)
        |> render_component(row: %{kind: :line, line_kind: :added, old_line: nil, new_line: 1, text: text})
        |> Floki.parse_fragment!()

      assert Floki.attribute(html, ".diff-code", "style") == hang
    end
  end

  test "a line that is not UTF-8 still measures its indent" do
    row = %{kind: :line, line_kind: :added, old_line: nil, new_line: 1, text: <<"  ", 0xFF, 0xFE>>}

    assert render_component(&DiffRow.diff_row/1, row: row) =~ "--hang: 6ch"
  end

  # Wrapping is drawn by the browser, so a copied line is the line and its
  # numbers and glyph are drawn once.
  test "a long line is drawn whole, with one pair of numbers and one glyph" do
    text = "  " <> String.duplicate("a long line of prose ", 40)
    row = %{kind: :line, line_kind: :context, old_line: 7, new_line: 9, text: text}

    html = (&DiffRow.diff_row/1) |> render_component(row: row) |> Floki.parse_fragment!()

    assert [{"span", [{"class", "diff-text"}], [^text]}] = Floki.find(html, ".diff-text")
    assert ["7", "9"] = html |> Floki.find(".diff-num") |> Enum.map(&Floki.text/1)
    assert [_glyph] = Floki.find(html, ".diff-glyph")
  end

  test "a hunk header, a gap and a binary notice carry nothing wrap reads" do
    gap = %{kind: :gap, path: "lib/filter.ex", gap_index: 0, start_line: 4, end_line: 39, old_start_line: 4, count: 36}

    for row <- [%{kind: :hunk_header, text: "@@ -1,3 +1,4 @@ def filter/2"}, gap, %{kind: :binary}] do
      html = render_component(&DiffRow.diff_row/1, row: row)

      refute html =~ "diff-text"
      refute html =~ "--hang"
    end
  end
end
