defmodule Rail.Domain.Diff.DiffRowModelTest do
  use Rail.DataCase, async: true

  alias Rail.Domain.Diff.BinaryNoticeRow
  alias Rail.Domain.Diff.DiffHunk
  alias Rail.Domain.Diff.DiffLine
  alias Rail.Domain.Diff.DiffRowLayout
  alias Rail.Domain.Diff.DiffRowModel
  alias Rail.Domain.Diff.FileDiff
  alias Rail.Domain.Diff.FileHeaderRow
  alias Rail.Domain.Diff.GapRow
  alias Rail.Domain.Diff.HunkHeaderRow
  alias Rail.Domain.Diff.LineRow

  test "flattens hunks, lines, gaps and binary notices correctly" do
    hunk1 =
      DiffHunk.new(
        header: "@@ -1,3 +1,3 @@",
        old_start: 1,
        old_count: 3,
        new_start: 1,
        new_count: 3,
        lines: [
          %DiffLine{kind: :context, old_line_number: 1, new_line_number: 1, text: "a"},
          %DiffLine{kind: :deleted, old_line_number: 2, new_line_number: nil, text: "b_old"},
          %DiffLine{kind: :added, old_line_number: nil, new_line_number: 2, text: "b_new"}
        ]
      )

    hunk2 =
      DiffHunk.new(
        header: "@@ -15,2 +15,2 @@",
        old_start: 15,
        old_count: 2,
        new_start: 15,
        new_count: 2,
        lines: [
          %DiffLine{kind: :context, old_line_number: 15, new_line_number: 15, text: "x"},
          %DiffLine{kind: :added, old_line_number: nil, new_line_number: 16, text: "y"}
        ]
      )

    file1 =
      FileDiff.new(%{
        new_path: "lib/file1.ex",
        status: :modified,
        hunks: [hunk1, hunk2],
        digest: "digest_1"
      })

    file2 =
      FileDiff.new(%{
        new_path: "assets/logo.png",
        status: :modified,
        is_binary: true,
        digest: "digest_2"
      })

    layout = DiffRowModel.build_rows([file1, file2])

    assert DiffRowLayout.row_count(layout) == 11

    # Row 0: File 1 header
    assert %FileHeaderRow{file: ^file1, is_viewed: false, extent: 40.0} = Enum.at(layout.rows, 0)
    assert DiffRowLayout.extent_at(layout, 0) == 40.0

    # Row 1: Hunk 1 header
    assert %HunkHeaderRow{file: ^file1, hunk: ^hunk1, extent: 28.0} = Enum.at(layout.rows, 1)

    # Rows 2..4: Hunk 1 lines (3 lines)
    assert %LineRow{line: %DiffLine{text: "a", line_index_in_file: 0}, extent: 22.0} = Enum.at(layout.rows, 2)
    assert %LineRow{line: %DiffLine{text: "b_old", line_index_in_file: 1}, extent: 22.0} = Enum.at(layout.rows, 3)
    assert %LineRow{line: %DiffLine{text: "b_new", line_index_in_file: 2}, extent: 22.0} = Enum.at(layout.rows, 4)

    # Row 5: Gap between hunk 1 (ends at new line 3) and hunk 2 (starts at new line 15)
    # Hidden lines: 4..14 (count = 11)
    assert %GapRow{
             file: ^file1,
             gap_index: 0,
             start_line: 4,
             end_line: 14,
             count: 11,
             old_start_line: 4,
             key: "lib/file1.ex:0",
             extent: 28.0
           } = Enum.at(layout.rows, 5)

    # Row 6: Hunk 2 header
    assert %HunkHeaderRow{file: ^file1, hunk: ^hunk2, extent: 28.0} = Enum.at(layout.rows, 6)

    # Rows 7..8: Hunk 2 lines (2 lines)
    assert %LineRow{line: %DiffLine{text: "x", line_index_in_file: 3}, extent: 22.0} = Enum.at(layout.rows, 7)
    assert %LineRow{line: %DiffLine{text: "y", line_index_in_file: 4}, extent: 22.0} = Enum.at(layout.rows, 8)

    # Row 9: File 2 header
    assert %FileHeaderRow{file: ^file2, is_viewed: false, extent: 40.0} = Enum.at(layout.rows, 9)

    # Row 10: File 2 binary notice
    assert %BinaryNoticeRow{file: ^file2, extent: 36.0} = Enum.at(layout.rows, 10)
  end

  test "precomputed offset_of_file matches exact sum of prior row extents" do
    hunk1 =
      DiffHunk.new(
        header: "@@ -1,3 +1,3 @@",
        old_start: 1,
        old_count: 3,
        new_start: 1,
        new_count: 3,
        lines: [
          %DiffLine{kind: :context, old_line_number: 1, new_line_number: 1, text: "a"},
          %DiffLine{kind: :deleted, old_line_number: 2, new_line_number: nil, text: "b_old"},
          %DiffLine{kind: :added, old_line_number: nil, new_line_number: 2, text: "b_new"}
        ]
      )

    hunk2 =
      DiffHunk.new(
        header: "@@ -15,2 +15,2 @@",
        old_start: 15,
        old_count: 2,
        new_start: 15,
        new_count: 2,
        lines: [
          %DiffLine{kind: :context, old_line_number: 15, new_line_number: 15, text: "x"},
          %DiffLine{kind: :added, old_line_number: nil, new_line_number: 16, text: "y"}
        ]
      )

    file1 =
      FileDiff.new(%{
        new_path: "lib/file1.ex",
        status: :modified,
        hunks: [hunk1, hunk2],
        digest: "digest_1"
      })

    file2 =
      FileDiff.new(%{
        new_path: "assets/logo.png",
        status: :modified,
        is_binary: true,
        digest: "digest_2"
      })

    layout = DiffRowModel.build_rows([file1, file2])

    assert Map.get(layout.offset_of_file, "lib/file1.ex") == 0.0

    # file 1 header (40) + hunk 1 header (28) + 3 lines (3 * 22 = 66) +
    # gap (28) + hunk 2 header (28) + 2 lines (2 * 22 = 44) = 234.0
    expected_file2_offset = 40.0 + 28.0 + 3 * 22.0 + 28.0 + 28.0 + 2 * 22.0
    assert Map.get(layout.offset_of_file, "assets/logo.png") == expected_file2_offset
  end

  test "viewed file collapses to header alone" do
    hunk =
      DiffHunk.new(
        header: "@@ -1,1 +1,1 @@",
        old_start: 1,
        new_start: 1,
        lines: [%DiffLine{kind: :context, old_line_number: 1, new_line_number: 1, text: "code"}]
      )

    file1 =
      FileDiff.new(%{
        new_path: "lib/file1.ex",
        status: :modified,
        hunks: [hunk],
        digest: "digest_1"
      })

    file2 =
      FileDiff.new(%{
        new_path: "assets/logo.png",
        status: :modified,
        is_binary: true,
        digest: "digest_2"
      })

    layout =
      DiffRowModel.build_rows(
        files: [file1, file2],
        viewed_files: %{"lib/file1.ex" => "digest_1"}
      )

    # File 1 is viewed: only header is emitted
    assert length(layout.rows) == 3
    assert %FileHeaderRow{file: ^file1, is_viewed: true} = Enum.at(layout.rows, 0)
    assert %FileHeaderRow{file: ^file2, is_viewed: false} = Enum.at(layout.rows, 1)
    assert %BinaryNoticeRow{file: ^file2} = Enum.at(layout.rows, 2)

    assert Map.get(layout.offset_of_file, "assets/logo.png") == 40.0
  end

  test "tracks max_line_chars across visible diff lines and expanded gaps" do
    hunk =
      DiffHunk.new(
        header: "@@ -1,1 +1,1 @@",
        old_start: 1,
        new_start: 1,
        lines: [
          %DiffLine{kind: :deleted, text: "b_old"},
          %DiffLine{kind: :added, text: "b_new"}
        ]
      )

    hunk2 =
      DiffHunk.new(
        header: "@@ -10,1 +10,1 @@",
        old_start: 10,
        new_start: 10,
        lines: [%DiffLine{kind: :added, text: "short"}]
      )

    file1 =
      FileDiff.new(%{
        new_path: "lib/file1.ex",
        status: :modified,
        hunks: [hunk, hunk2],
        digest: "digest_1"
      })

    layout = DiffRowModel.build_rows([file1])
    assert layout.max_line_chars == 5

    layout_with_gap =
      DiffRowModel.build_rows([file1], %{}, %{
        "lib/file1.ex:0" => ["this is a longer line in the gap"]
      })

    assert layout_with_gap.max_line_chars == 32
  end

  test "expanded gaps replace GapRow with LineRow items" do
    hunk1 =
      DiffHunk.new(
        header: "@@ -1,1 +1,1 @@",
        old_start: 1,
        old_count: 1,
        new_start: 1,
        new_count: 1,
        lines: [%DiffLine{kind: :context, old_line_number: 1, new_line_number: 1, text: "head"}]
      )

    hunk2 =
      DiffHunk.new(
        header: "@@ -15,1 +15,1 @@",
        old_start: 15,
        old_count: 1,
        new_start: 15,
        new_count: 1,
        lines: [%DiffLine{kind: :context, old_line_number: 15, new_line_number: 15, text: "tail"}]
      )

    file1 =
      FileDiff.new(%{
        new_path: "lib/file1.ex",
        status: :modified,
        hunks: [hunk1, hunk2],
        digest: "digest_1"
      })

    gap_key = "lib/file1.ex:0"
    fetched_lines = Enum.map(4..14, fn i -> "hidden_line_#{i}" end)

    layout =
      DiffRowModel.build_rows([file1], %{}, %{gap_key => fetched_lines})

    # GapRow should not exist in rows
    assert Enum.any?(layout.rows, &is_struct(&1, GapRow)) == false

    # Index 2 should be the first expanded line (after header + hunk1_header + line1)
    # FileHeader(0) + Hunk1Header(1) + line(2) -> expanded lines start at 3
    assert %LineRow{
             line: %DiffLine{kind: :context, old_line_number: 2, new_line_number: 2, text: "hidden_line_4"},
             line_index_in_file: nil
           } = Enum.at(layout.rows, 3)

    last_expanded = Enum.at(layout.rows, 13)
    assert last_expanded.line.kind == :context
    assert last_expanded.line.text == "hidden_line_14"
    assert is_nil(last_expanded.line_index_in_file)
  end

  test "groups rows into sections with headers, body_rows, and start offsets" do
    hunk =
      DiffHunk.new(
        header: "@@ -1,1 +1,1 @@",
        old_start: 1,
        new_start: 1,
        lines: [%DiffLine{kind: :added, text: "code"}]
      )

    file1 =
      FileDiff.new(%{
        new_path: "lib/file1.ex",
        status: :added,
        hunks: [hunk],
        digest: "digest_1"
      })

    file2 =
      FileDiff.new(%{
        new_path: "assets/logo.png",
        status: :modified,
        is_binary: true,
        digest: "digest_2"
      })

    layout = DiffRowModel.build_rows([file1, file2])

    assert length(layout.sections) == 2

    # Section 1
    sec1 = Enum.at(layout.sections, 0)
    assert sec1.file.path == "lib/file1.ex"
    assert sec1.header.is_viewed == false
    assert sec1.start_offset == 0.0
    assert length(sec1.body_rows) == 2

    # Section 2
    sec2 = Enum.at(layout.sections, 1)
    assert sec2.file.path == "assets/logo.png"
    assert sec2.start_offset == 40.0 + 28.0 + 22.0
    assert length(sec2.body_rows) == 1
    assert [%BinaryNoticeRow{}] = sec2.body_rows
  end

  test "viewed file produces section with empty body_rows" do
    hunk =
      DiffHunk.new(
        header: "@@ -1,1 +1,1 @@",
        old_start: 1,
        new_start: 1,
        lines: [%DiffLine{kind: :added, text: "code"}]
      )

    file1 =
      FileDiff.new(%{
        new_path: "lib/file1.ex",
        status: :added,
        hunks: [hunk],
        digest: "digest_1"
      })

    file2 =
      FileDiff.new(%{
        new_path: "assets/logo.png",
        status: :modified,
        is_binary: true,
        digest: "digest_2"
      })

    layout =
      DiffRowModel.build_rows([file1, file2], %{"lib/file1.ex" => "digest_1"})

    assert length(layout.sections) == 2
    sec1 = Enum.at(layout.sections, 0)
    assert sec1.header.is_viewed == true
    assert sec1.body_rows == []
    assert sec1.start_offset == 0.0

    sec2 = Enum.at(layout.sections, 1)
    assert sec2.header.is_viewed == false
    assert sec2.start_offset == 40.0
  end

  test "handles contiguous hunks with zero gap count" do
    hunk1 =
      DiffHunk.new(
        header: "@@ -1,2 +1,2 @@",
        old_start: 1,
        old_count: 2,
        new_start: 1,
        new_count: 2,
        lines: [%DiffLine{kind: :context, old_line_number: 1, new_line_number: 1, text: "a"}]
      )

    hunk2 =
      DiffHunk.new(
        header: "@@ -3,2 +3,2 @@",
        old_start: 3,
        old_count: 2,
        new_start: 3,
        new_count: 2,
        lines: [%DiffLine{kind: :context, old_line_number: 3, new_line_number: 3, text: "c"}]
      )

    file =
      FileDiff.new(%{
        new_path: "lib/contiguous.ex",
        status: :modified,
        hunks: [hunk1, hunk2],
        digest: "digest_cont"
      })

    layout = DiffRowModel.build_rows([file], nil)
    # No GapRow should be emitted between hunk1 and hunk2
    assert Enum.any?(layout.rows, &is_struct(&1, GapRow)) == false
  end
end
