defmodule RailWeb.Utils.BuildDocumentBlocksTest do
  use ExUnit.Case, async: true

  import RailWeb.Utils.BuildDocumentBlocks

  @ticket """
  QA starts recording the moment the browser paints.

  ## Acceptance criteria

  - A recording starts on the loaded page.
  - A page that never goes idle starts after 10 seconds.
  - Demo starts on the same frame.
    - QA and Demo use the same cap.
    - Demo waits on the same events as QA.

  ## Waits by page

  | Page | Cap |
  |------|-----|
  | Overview | 5 s |
  | Sandboxes | 10 s |

  > every recording opens on three seconds of white

  ```elixir
  config :rail, Rail.QA,
    settle_cap_ms: 10_000
  ```
  """

  test "every heading, paragraph, list item, table row, blockquote and code line is a line with its kind and label" do
    assert [
             %{kind: :paragraph, label: "Paragraph 1", text: "QA starts recording the moment the browser paints."},
             %{kind: :heading, label: "Heading 1", text: "Acceptance criteria"},
             %{kind: :list_item, label: "Criterion 1", depth: 0, marker: :bullet},
             %{kind: :list_item, label: "Criterion 2", text: "A page that never goes idle starts after 10 seconds."},
             %{kind: :list_item, label: "Criterion 3", text: "Demo starts on the same frame.", depth: 0},
             %{kind: :list_item, label: "Criterion 3.1", depth: 1},
             %{kind: :list_item, label: "Criterion 3.2", text: "Demo waits on the same events as QA.", depth: 1},
             %{kind: :heading, label: "Heading 2", text: "Waits by page"},
             %{kind: :table_row, label: "Table header", text: "Page | Cap", header?: true, columns: 2, first?: true},
             %{kind: :table_row, label: "Table row 1", text: "Overview | 5 s", header?: false},
             %{kind: :table_row, label: "Table row 2", text: "Sandboxes | 10 s", last?: true},
             %{kind: :blockquote, label: "Blockquote 1", text: "every recording opens on three seconds of white"},
             %{kind: :code, label: "Code line 1", text: "config :rail, Rail.QA,", number: 1, first?: true},
             %{kind: :code, label: "Code line 2", text: "  settle_cap_ms: 10_000", number: 2, last?: true}
           ] = build_document_blocks(@ticket)
  end

  test "a list item holds only its own text, and its html only its own content" do
    [_paragraph, _heading, _first, _second, parent | _rest] = build_document_blocks(@ticket)

    assert parent.html =~ "Demo starts on the same frame."
    refute parent.html =~ "same cap"
  end

  test "editing a nested item leaves its parent's key alone" do
    before = build_document_blocks(@ticket)
    edited = build_document_blocks(String.replace(@ticket, "the same cap", "a cap of their own"))

    assert Enum.at(before, 4).key == Enum.at(edited, 4).key
    refute Enum.at(before, 5).key == Enum.at(edited, 5).key
  end

  test "lines that read the same are told apart by their occurrence" do
    assert [
             %{text: "Same.", occurrence: 1, key: first},
             %{kind: :heading, text: "Same.", occurrence: 1},
             %{text: "Same.", occurrence: 2, key: second}
           ] = build_document_blocks("Same.\n\n# Same.\n\nSame.\n")

    refute first == second
  end

  test "a list elsewhere is labelled by its section and position, an ordered or task item by its marker" do
    assert [
             %{label: "Item 1", marker: {:ordered, 3}},
             %{kind: :heading},
             %{label: "Out of scope, item 1", marker: {:task, true}, text: "Trimming"},
             %{label: "Out of scope, item 1.1", marker: :bullet}
           ] = build_document_blocks("3. First\n\n## Out of scope\n\n- [x] Trimming\n  - its end\n")
  end

  test "a second table and code block say which they are, and a rule or an empty document has no lines" do
    assert [
             %{label: "Code line 1"},
             %{label: "Table header"},
             %{label: "Table row 1"},
             %{label: "Code block 2, line 1"},
             %{label: "Table 2, header"},
             %{label: "Table 2, row 1"}
           ] =
             build_document_blocks("```\na\n```\n\n| A |\n|---|\n| 1 |\n\n---\n\n```\nb\n```\n\n| B |\n|---|\n| 2 |\n")

    assert build_document_blocks("") == []
  end

  test "words split by emphasis or a soft break read as written, and raw HTML is escaped" do
    assert [%{text: "Say bold now and next", html: html}, %{text: "<b>x</b>", html: block}] =
             build_document_blocks("Say **bold** now\nand next\n\n<b>x</b>\n")

    assert html =~ "<strong>bold</strong>"
    refute block =~ "<b>"
  end

  test "a blockquote holding a list reads as one line, its items kept apart" do
    assert [%{kind: :blockquote, text: "first second"}] = build_document_blocks("> - first\n> - second\n")
  end
end
