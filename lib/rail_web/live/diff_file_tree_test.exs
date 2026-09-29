defmodule RailWeb.Live.DiffFileTreeTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias RailWeb.Live.DiffFileTree

  setup do
    file = %{path: "lib/rail/invoices/filter.ex", display_path: "lib/rail/invoices/filter.ex", status: :modified}

    %{
      tree: %{
        id: "diff-file-tree",
        target: nil,
        show?: true,
        label: "1 file changed",
        rows: [%{id: file.path, file: Map.merge(file, %{additions: 2, deletions: 1}), viewed?: false, selected?: false}]
      }
    }
  end

  test "lists each file by name under how many there are", %{tree: tree} do
    html = render_component(DiffFileTree, tree)

    assert html =~ "1 file changed"
    assert html =~ "filter.ex"
    assert html =~ "lib/rail/invoices"
    refute html =~ ~s(aria-current="true")
  end

  test "marks the file the reader selected", %{tree: tree} do
    [row] = tree.rows

    assert render_component(DiffFileTree, %{tree | rows: [%{row | selected?: true}]}) =~ ~s(aria-current="true")
  end

  test "marks a file the reader has read", %{tree: tree} do
    [row] = tree.rows

    assert render_component(DiffFileTree, %{tree | rows: [%{row | viewed?: true}]}) =~ "pi-check-circle"
  end

  # The end of a path is what says which file it is, so a long one loses its start.
  test "shortens a deep directory from the front", %{tree: tree} do
    [row] = tree.rows
    deep = "lib/rail_web/live/settings/components/forms/fields/deep.ex"

    html = render_component(DiffFileTree, %{tree | rows: [%{row | file: %{row.file | display_path: deep}}]})

    assert html =~ "…"
    assert html =~ "components/forms/fields"
  end

  test "hides the list when the reader has put it away", %{tree: tree} do
    refute render_component(DiffFileTree, %{tree | show?: false}) =~ "diff_file_tree"
  end
end
