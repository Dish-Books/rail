defmodule RailWeb.Live.DiffFileTreeTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Rail.Pipeline.Schemas.DiffComment
  alias RailWeb.Live.DiffFileTree

  setup do
    file = %{path: "lib/rail/invoices/filter.ex", display_path: "lib/rail/invoices/filter.ex", status: :modified}

    %{
      tree: %{
        id: "diff-file-tree",
        target: nil,
        show?: true,
        label: "1 file changed",
        rows: [
          %{
            id: file.path,
            file: Map.merge(file, %{additions: 2, deletions: 1}),
            viewed?: false,
            selected?: false,
            unsent: 0
          }
        ],
        list: :files,
        file_count: 1,
        comment_count: 0,
        selected_comment: nil,
        groups: []
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

  test "switches between the files and the reader's comments, counting each", %{tree: tree} do
    comment = %DiffComment{
      id: "dcm_listed",
      path: "lib/rail/invoices/filter.ex",
      line_kind: :added,
      line: 3,
      line_text: "x",
      filter: :branch,
      body: "Name it.",
      status: :sent
    }

    tree = %{
      tree
      | comment_count: 1,
        groups: [%{status: :sent, label: "Sent", rows: [%{comment: comment, changed?: false}]}]
    }

    files = render_component(DiffFileTree, tree)

    assert files =~ ~r/aria-pressed="true"[^>]*>\s*Files 1\s*<.*Comments 1/s
    assert files =~ ~s(phx-click="select_diff_list")
    assert files =~ "diff-file-row"
    refute files =~ "diff_comment_list"

    comments = render_component(DiffFileTree, %{tree | list: :comments})

    assert comments =~ ~r/Files 1.*aria-pressed="true"[^>]*>\s*Comments 1/s
    assert comments =~ "Name it."
    refute comments =~ "diff-file-row"
    refute comments =~ "1 file changed"
  end

  test "counts a file's unsent comments beside its name", %{tree: tree} do
    [row] = tree.rows

    refute render_component(DiffFileTree, tree) =~ "diff_file_unsent"

    html = render_component(DiffFileTree, %{tree | rows: [%{row | unsent: 2}]})

    assert [{_tag, _attrs, _children} = count] =
             html |> Floki.parse_fragment!() |> Floki.find("[data-qa='diff_file_unsent']")

    assert Floki.text(count) =~ "2"
    assert Floki.attribute(count, "title") == ["2 unsent comments"]
  end
end
