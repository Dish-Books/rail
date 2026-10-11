defmodule RailWeb.Components.DiffHunkTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias RailWeb.Components.DiffHunk

  test "named rows draw one bracket, start to end, and each keeps its own kind" do
    rows = [
      %{kind: :line, line_kind: :context, old_line: 1, new_line: 1, text: "defmodule Filter do"},
      %{kind: :line, line_kind: :deleted, old_line: 2, new_line: nil, text: "  def filter(list)", named?: true},
      %{kind: :line, line_kind: :added, old_line: nil, new_line: 2, text: "  def filter(list, by)", named?: true},
      %{kind: :line, line_kind: :context, old_line: 3, new_line: 3, text: "  end", named?: true},
      %{kind: :line, line_kind: :context, old_line: 4, new_line: 4, text: "end"}
    ]

    html = (&DiffHunk.diff_hunk/1) |> render_component(rows: rows) |> Floki.parse_fragment!()

    assert [nil, "start", "middle", "end", nil] =
             html
             |> Floki.find(".diff-bracket-row")
             |> Enum.map(&(&1 |> Floki.attribute("data-bracket") |> List.first()))

    assert ["context", "deleted", "added", "context", "context"] =
             html |> Floki.find(".diff-bracket-row > .diff-line") |> Enum.flat_map(&Floki.attribute(&1, "data-kind"))
  end

  test "a lone named row is both ends of its bracket" do
    rows = [
      %{kind: :line, line_kind: :context, old_line: 1, new_line: 1, text: "a"},
      %{kind: :line, line_kind: :added, old_line: nil, new_line: 2, text: "b", named?: true}
    ]

    html = (&DiffHunk.diff_hunk/1) |> render_component(rows: rows) |> Floki.parse_fragment!()

    assert [_row] = Floki.find(html, ".diff-bracket-row[data-bracket=only] .diff-line[data-kind=added]")
    assert [_one, _two] = Floki.find(html, ".diff-bracket")
  end

  # A finding's excerpt is not the diff, so it takes no comments of its own.
  test "offers no comment on a line" do
    rows = [%{kind: :line, line_kind: :added, old_line: nil, new_line: 1, text: "defmodule Filter do"}]

    refute render_component(&DiffHunk.diff_hunk/1, rows: rows) =~ "diff_comment_add"
  end

  # The excerpt reads as the pane does, so the reader's wrap reaches it too.
  test "draws its lines in the same body as a file of the diff pane" do
    rows = [%{kind: :line, line_kind: :added, old_line: nil, new_line: 1, text: "defmodule Filter do"}]

    html = (&DiffHunk.diff_hunk/1) |> render_component(rows: rows) |> Floki.parse_fragment!()

    assert [_line] = Floki.find(html, "[data-qa='diff_hunk'].diff-body > .diff-rows > .diff-bracket-row > .diff-line")
  end
end
