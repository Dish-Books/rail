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
    assert html =~ "Expand 36 hidden lines"
    assert html =~ ~s(phx-value-gap_index="0")
    assert html =~ ~s(phx-value-path="lib/rail/invoices/filter.ex")
    assert html =~ ~s(phx-target="2")
  end

  test "draws the fetched lines in place of the gap once it is opened", %{diff: diff} do
    html =
      render_component(&DiffPane.diff_pane/1,
        files: [diff],
        expanded_gaps: %{"lib/rail/invoices/filter.ex:0" => ["  # in between"]}
      )

    refute html =~ "diff_gap_row"
    assert html =~ "# in between"
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

  test "a file already read collapses to its header", %{diff: diff} do
    html = render_component(&DiffPane.diff_pane/1, files: [Map.put(diff, :viewed?, true)])

    refute html =~ ~s(data-kind="added")
    assert html =~ "filter.ex"
  end

  test "marks the file the reader selected", %{diff: diff} do
    html = render_component(&DiffPane.diff_pane/1, files: [diff], selected_file: diff.path)

    assert html =~ "bg-blue-100"
  end

  test "hides the file tree when the caller does not want one", %{diff: diff} do
    html = render_component(&DiffPane.diff_pane/1, files: [diff], show_file_tree: false)

    refute html =~ "diff_file_tree"
    assert html =~ "diff_row_list"
  end
end
