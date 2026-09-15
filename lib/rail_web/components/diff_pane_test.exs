defmodule RailWeb.Components.DiffPaneTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import Rail.Git.Utils.ParseDiff

  alias RailWeb.Components.DiffPane

  setup do
    raw = """
    diff --git a/lib/rail/invoices/filter.ex b/lib/rail/invoices/filter.ex
    --- a/lib/rail/invoices/filter.ex
    +++ b/lib/rail/invoices/filter.ex
    @@ -1,3 +1,4 @@ def filter/2
     defmodule Filter do
    -  def filter(list), do: list
    +  def filter(list, vendor) do
    +    Enum.filter(list, vendor)
    @@ -40,2 +41,2 @@
     end
    """

    [file] = parse_diff(raw)

    %{diff: Map.put(file, :viewed?, false)}
  end

  test "says so when there is nothing to read" do
    html = render_component(&DiffPane.diff_pane/1, files: [], empty_message: "Nothing on this branch yet.")

    assert html =~ "Nothing on this branch yet."
    assert html =~ "diff_empty_state"
  end

  test "draws every kind of line, and the directories the files sit in", %{diff: diff} do
    html = render_component(&DiffPane.diff_pane/1, files: [diff])

    assert html =~ "invoices"
    assert html =~ "filter.ex"
    assert html =~ ~s(data-kind="context")
    assert html =~ ~s(data-kind="deleted")
    assert html =~ ~s(data-kind="added")
    assert html =~ "def filter/2"
  end

  test "offers to expand the unchanged lines between two hunks", %{diff: diff} do
    html = render_component(&DiffPane.diff_pane/1, files: [diff], target: "2")

    assert html =~ "diff_gap_row"
    assert html =~ "Expand 36 unchanged lines"
    assert html =~ ~s(phx-value-gap_index="0")
    assert html =~ ~s(phx-value-path="lib/rail/invoices/filter.ex")
    assert html =~ ~s(phx-target="2")
  end

  test "draws the fetched lines in place of the gap once it is opened", %{diff: diff} do
    html =
      render_component(&DiffPane.diff_pane/1,
        files: [diff],
        expanded_gaps: %{"lib/rail/invoices/filter.ex:0" => [%{text: "  # in between", html: nil}]}
      )

    refute html =~ "diff_gap_row"
    assert html =~ "# in between"
  end

  test "draws the highlighted code when the line came with any", %{diff: diff} do
    rows = Enum.map(diff.rows, &Map.put(&1, :html, ~s|<span class="l-keyword">def</span>|))

    html = render_component(&DiffPane.diff_pane/1, files: [%{diff | rows: rows}])

    assert html =~ ~s(<span class="l-keyword">def</span>)
  end

  test "stands in for a binary file rather than drawing it" do
    [logo] = parse_diff("diff --git a/assets/logo.png b/assets/logo.png\nBinary files a/x and b/y differ\n")

    assert render_component(&DiffPane.diff_pane/1, files: [Map.put(logo, :viewed?, false)]) =~
             "Binary file not shown"
  end

  test "names both sides of a renamed file" do
    [renamed] =
      parse_diff("diff --git a/lib/old_name.ex b/lib/new_name.ex\n--- a/lib/old_name.ex\n+++ b/lib/new_name.ex\n")

    html = render_component(&DiffPane.diff_pane/1, files: [Map.put(renamed, :viewed?, false)])

    assert html =~ "lib/old_name.ex → lib/new_name.ex"
  end

  test "a collapsed file is only its header", %{diff: diff} do
    html = render_component(&DiffPane.diff_pane/1, files: [diff], collapsed: [diff.path])

    refute html =~ ~s(data-kind="added")
    assert html =~ "filter.ex"
  end

  test "says a file has been read, in the row and in the count", %{diff: diff} do
    html = render_component(&DiffPane.diff_pane/1, files: [Map.put(diff, :viewed?, true)])

    assert html =~ ~s(aria-pressed="true")
    assert html =~ "1/1"
  end

  test "marks the file the reader selected", %{diff: diff} do
    html = render_component(&DiffPane.diff_pane/1, files: [diff], selected_file: diff.path)

    assert html =~ ~s(aria-current="true")
  end

  test "totals the whole diff over the files it is showing", %{diff: diff} do
    html =
      render_component(&DiffPane.diff_pane/1,
        files: [diff, %{diff | path: "mix.exs", display_path: "mix.exs", additions: 8, deletions: 2}],
        query: "filter"
      )

    assert html =~ "2 files changed"
    assert html =~ "+10"
    assert html =~ "-3"
    refute html =~ ~s(phx-value-path="mix.exs")
  end

  test "says so when the query leaves nothing", %{diff: diff} do
    html = render_component(&DiffPane.diff_pane/1, files: [diff], query: "nothing-like-this")

    assert html =~ "No file here matches nothing-like-this."
    refute html =~ "diff_file_section"
  end

  test "calls out what became of a file the change did not only edit", %{diff: diff} do
    for {status, label} <- [added: "new file", deleted: "deleted", renamed: "renamed"] do
      assert render_component(&DiffPane.diff_pane/1, files: [%{diff | status: status}]) =~ label
    end

    refute render_component(&DiffPane.diff_pane/1, files: [diff]) =~ "diff_status_badge"
  end

  test "hides the file tree when the caller does not want one", %{diff: diff} do
    html = render_component(&DiffPane.diff_pane/1, files: [diff], show_file_tree: false)

    refute html =~ "diff_file_tree"
    assert html =~ "diff_row_list"
  end
end
