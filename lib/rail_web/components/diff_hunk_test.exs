defmodule RailWeb.Components.DiffHunkTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias RailWeb.Components.DiffHunk

  test "a focused line says so, and no other does" do
    rows = [
      %{kind: :hunk_header, text: "@@ -1,2 +1,2 @@"},
      %{kind: :line, line_kind: :context, old_line: 1, new_line: 1, text: "defmodule Filter do"},
      %{kind: :line, line_kind: :deleted, old_line: 2, new_line: nil, text: "  def filter(list), do: list", focus?: true}
    ]

    html = (&DiffHunk.diff_hunk/1) |> render_component(rows: rows) |> Floki.parse_fragment!()

    assert [_header] = Floki.find(html, "[data-qa='diff_hunk_header']")
    assert [focused] = Floki.find(html, "[data-focus]")
    assert Floki.text(focused) =~ "def filter(list), do: list"
  end
end
