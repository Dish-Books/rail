defmodule RailWeb.Components.DiffPaneTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import RailWeb.Components.DiffPane

  alias Rail.Domain.Diff.DiffHunk
  alias Rail.Domain.Diff.DiffLine
  alias Rail.Domain.Diff.FileDiff

  test "renders empty state with default and custom message when files is empty" do
    html_default = render_component(&diff_pane/1, files: [])

    assert html_default =~ "diff-empty-state"
    assert html_default =~ "Nothing has been changed on this branch yet."

    html_custom = render_component(&diff_pane/1, files: [], empty_message: "No modifications")
    assert html_custom =~ "No modifications"
  end

  test "build_flattened_tree/1 sorts directories before files and by depth" do
    file1 = FileDiff.new(%{status: :modified, digest: "d1", new_path: "lib/rail/foo.ex"})
    file2 = FileDiff.new(%{status: :modified, digest: "d2", new_path: "lib/rail/bar.ex"})
    file3 = FileDiff.new(%{status: :modified, digest: "d3", new_path: "assets/css/app.css"})
    file4 = FileDiff.new(%{status: :modified, digest: "d4", new_path: "README.md"})

    items = build_flattened_tree([file1, file2, file3, file4])

    assert [
             %{type: :dir, name: "assets", depth: 0},
             %{type: :dir, name: "css", depth: 1},
             %{type: :file, name: "app.css", depth: 2},
             %{type: :dir, name: "lib", depth: 0},
             %{type: :dir, name: "rail", depth: 1},
             %{type: :file, name: "bar.ex", depth: 2},
             %{type: :file, name: "foo.ex", depth: 2},
             %{type: :file, name: "README.md", depth: 0}
           ] = items
  end

  test "renders two-column layout with file tree, headers, diff rows, and binary notices" do
    hunk =
      DiffHunk.new(
        header: "@@ -1,3 +1,3 @@",
        section_heading: "def start",
        old_start: 1,
        old_count: 3,
        new_start: 1,
        new_count: 3,
        lines: [
          %DiffLine{kind: :context, old_line_number: 1, new_line_number: 1, text: "line 1"},
          %DiffLine{kind: :deleted, old_line_number: 2, new_line_number: nil, text: "line 2 old"},
          %DiffLine{kind: :added, old_line_number: nil, new_line_number: 2, text: "line 2 new"}
        ]
      )

    file_text =
      FileDiff.new(%{
        old_path: "lib/old_path.ex",
        new_path: "lib/new_path.ex",
        status: :renamed,
        is_renamed: true,
        hunks: [hunk],
        additions: 1,
        deletions: 1,
        digest: "digest_text"
      })

    file_binary =
      FileDiff.new(%{
        new_path: "assets/image.png",
        status: :modified,
        is_binary: true,
        digest: "digest_bin"
      })

    html =
      render_component(&diff_pane/1,
        files: [file_text, file_binary],
        viewed: %{},
        selected_file: "lib/new_path.ex",
        show_file_tree: true
      )

    # File tree
    assert html =~ "diff-file-tree"
    assert html =~ "new_path.ex"
    assert html =~ "image.png"
    assert html =~ "phx-click=\"select_diff_file\""

    # Renamed display path in header
    assert html =~ "lib/old_path.ex → lib/new_path.ex"
    assert html =~ "Viewed"
    assert html =~ "phx-click=\"toggle_viewed\""

    # Hunk header and line rows
    assert html =~ "@@ -1,3 +1,3 @@  def start"
    assert html =~ "line 1"
    assert html =~ "line 2 old"
    assert html =~ "line 2 new"

    # Binary file notice
    assert html =~ "Binary file not shown"
  end

  test "collapses file body when file is viewed" do
    hunk =
      DiffHunk.new(
        header: "@@ -1,1 +1,1 @@",
        old_start: 1,
        new_start: 1,
        lines: [%DiffLine{kind: :added, new_line_number: 1, text: "secret line"}]
      )

    file =
      FileDiff.new(%{
        new_path: "lib/viewed.ex",
        status: :added,
        hunks: [hunk],
        additions: 1,
        deletions: 0,
        digest: "d_viewed"
      })

    html_viewed =
      render_component(&diff_pane/1,
        files: [file],
        viewed: %{"lib/viewed.ex" => "d_viewed"}
      )

    # Header is present
    assert html_viewed =~ "lib/viewed.ex"
    # But body rows are NOT rendered
    refute html_viewed =~ "secret line"

    html_viewed_nil =
      render_component(&diff_pane/1,
        files: [file],
        viewed: nil
      )

    assert html_viewed_nil =~ "lib/viewed.ex"
    assert html_viewed_nil =~ "secret line"
  end

  test "renders and expands gaps when expanded_gaps contains the key" do
    hunk1 =
      DiffHunk.new(
        header: "@@ -1,2 +1,2 @@",
        old_start: 1,
        old_count: 2,
        new_start: 1,
        new_count: 2,
        lines: [
          %DiffLine{kind: :context, old_line_number: 1, new_line_number: 1, text: "h1 l1"},
          %DiffLine{kind: :context, old_line_number: 2, new_line_number: 2, text: "h1 l2"}
        ]
      )

    hunk2 =
      DiffHunk.new(
        header: "@@ -10,2 +10,2 @@",
        old_start: 10,
        old_count: 2,
        new_start: 10,
        new_count: 2,
        lines: [
          %DiffLine{kind: :context, old_line_number: 10, new_line_number: 10, text: "h2 l1"},
          %DiffLine{kind: :context, old_line_number: 11, new_line_number: 11, text: "h2 l2"}
        ]
      )

    file =
      FileDiff.new(%{
        new_path: "lib/gaps.ex",
        status: :modified,
        hunks: [hunk1, hunk2],
        digest: "d_gaps"
      })

    # Unexpanded gap: 7 hidden lines (3..9)
    html_unexpanded =
      render_component(&diff_pane/1,
        files: [file],
        viewed: %{},
        expanded_gaps: %{}
      )

    assert html_unexpanded =~ "Expand 7 hidden lines"
    assert html_unexpanded =~ "phx-click=\"expand_gap\""

    # Expanded gap: lines inserted in place
    html_expanded =
      render_component(&diff_pane/1,
        files: [file],
        viewed: %{},
        expanded_gaps: %{"lib/gaps.ex:0" => ["expanded line 3", "expanded line 4"]}
      )

    refute html_expanded =~ "Expand 7 hidden lines"
    assert html_expanded =~ "expanded line 3"
    assert html_expanded =~ "expanded line 4"
  end

  test "omits file tree when show_file_tree is false and supports list viewed" do
    file =
      FileDiff.new(%{
        new_path: "lib/simple.ex",
        status: :modified,
        hunks: [],
        digest: "d_simple"
      })

    html =
      render_component(&diff_pane/1,
        files: [file],
        viewed: ["lib/simple.ex"],
        show_file_tree: false
      )

    refute html =~ "diff-file-tree"
    assert html =~ "diff-row-list"
  end

  test "handles viewed nil and empty section heading in hunk header" do
    hunk =
      DiffHunk.new(
        header: "@@ -1,2 +1,2 @@",
        section_heading: "",
        old_start: 1,
        new_start: 1,
        lines: [%DiffLine{kind: :context, old_line_number: 1, new_line_number: 1, text: "c"}]
      )

    file =
      FileDiff.new(%{
        new_path: "lib/plain.ex",
        status: :modified,
        hunks: [hunk],
        digest: "d_plain"
      })

    html =
      render_component(&diff_pane/1,
        files: [file],
        viewed: nil
      )

    assert html =~ "lib/plain.ex"
    assert html =~ "@@ -1,2 +1,2 @@"
    refute html =~ "@@ -1,2 +1,2 @@  "
  end
end
