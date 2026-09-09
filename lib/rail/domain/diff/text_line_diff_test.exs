defmodule Rail.Domain.Diff.TextLineDiffTest do
  use Rail.DataCase, async: true

  alias Rail.Domain.Diff.DiffHunk
  alias Rail.Domain.Diff.DiffLine
  alias Rail.Domain.Diff.FileDiff
  alias Rail.Domain.Diff.TextLineDiff

  test "no-change produces empty hunks and unchanged status" do
    text = "line 1\nline 2\nline 3"
    diff = TextLineDiff.diff(text, text, "test.txt")

    assert %FileDiff{
             status: :unchanged,
             hunks: [],
             additions: 0,
             deletions: 0,
             path: "test.txt"
           } = diff
  end

  test "insert adds a line with correct hunk and addition count" do
    before = "line 1\nline 3"
    after_text = "line 1\nline 2\nline 3"
    diff = TextLineDiff.diff(before, after_text, "test.txt")

    assert %FileDiff{
             status: :modified,
             additions: 1,
             deletions: 0,
             hunks: [
               %DiffHunk{
                 lines: [
                   %DiffLine{kind: :context, text: "line 1"},
                   %DiffLine{kind: :added, old_line_number: nil, new_line_number: 2, text: "line 2"},
                   %DiffLine{kind: :context, text: "line 3"}
                 ]
               }
             ]
           } = diff
  end

  test "delete removes a line with correct hunk and deletion count" do
    before = "line 1\nline 2\nline 3"
    after_text = "line 1\nline 3"
    diff = TextLineDiff.diff(before, after_text, "test.txt")

    assert %FileDiff{
             status: :modified,
             additions: 0,
             deletions: 1,
             hunks: [
               %DiffHunk{
                 lines: [
                   %DiffLine{kind: :context, text: "line 1"},
                   %DiffLine{kind: :deleted, old_line_number: 2, new_line_number: nil, text: "line 2"},
                   %DiffLine{kind: :context, text: "line 3"}
                 ]
               }
             ]
           } = diff
  end

  test "replace modifies lines into deletion followed by addition" do
    before = "line 1\nline 2\nline 3"
    after_text = "line 1\nline 2 modified\nline 3"
    diff = TextLineDiff.diff(before, after_text, "test.txt")

    assert %FileDiff{
             status: :modified,
             additions: 1,
             deletions: 1,
             hunks: [
               %DiffHunk{
                 lines: [
                   %DiffLine{kind: :context, text: "line 1"},
                   %DiffLine{kind: :deleted, text: "line 2"},
                   %DiffLine{kind: :added, text: "line 2 modified"},
                   %DiffLine{kind: :context, text: "line 3"}
                 ]
               }
             ]
           } = diff
  end

  test "context window splits distant changes and merges close ones" do
    lines_before = Enum.map(1..20, fn i -> "line #{i}" end)

    # Distant changes: line 2 and line 19 (distance is 17 lines, well above 2 * 3 = 6)
    lines_distant_after =
      lines_before
      |> List.replace_at(1, "line 2 changed")
      |> List.replace_at(18, "line 19 changed")

    diff_distant =
      TextLineDiff.diff(
        Enum.join(lines_before, "\n"),
        Enum.join(lines_distant_after, "\n"),
        "test.txt"
      )

    # Distant changes split into 2 hunks
    assert length(diff_distant.hunks) == 2
    [hunk1, hunk2] = diff_distant.hunks
    assert Enum.count(hunk1.lines, &(&1.kind == :context)) == 4
    assert Enum.count(hunk2.lines, &(&1.kind == :context)) == 4

    # Close changes: line 2 and line 6 (distance is 3 lines <= 6)
    lines_close_after =
      lines_before
      |> List.replace_at(1, "line 2 changed")
      |> List.replace_at(5, "line 6 changed")

    diff_close =
      TextLineDiff.diff(
        Enum.join(lines_before, "\n"),
        Enum.join(lines_close_after, "\n"),
        "test.txt"
      )

    # Close changes merge into 1 hunk
    assert length(diff_close.hunks) == 1
  end

  test "trailing newline is handled cleanly without phantom lines" do
    before_nl = "line 1\nline 2\n"
    after_nl = "line 1\nline 2\nline 3\n"

    diff1 = TextLineDiff.diff(before_nl, after_nl, "test.txt")
    assert diff1.additions == 1
    assert diff1.deletions == 0
    assert List.last(hd(diff1.hunks).lines).text == "line 3"

    before_no_nl = "line 1\nline 2"
    after_no_nl = "line 1\nline 2\nline 3"

    diff2 = TextLineDiff.diff(before_no_nl, after_no_nl, "test.txt")
    assert diff2.additions == 1
    assert diff2.deletions == 0
    assert List.last(hd(diff2.hunks).lines).text == "line 3"
  end

  test "current ending in newline vs trimmed proposal yields unchanged status and zero hunks" do
    before = "line 1\nline 2\n"
    after_text = "line 1\nline 2"
    diff = TextLineDiff.diff(before, after_text, "test.txt")

    assert %FileDiff{
             status: :unchanged,
             hunks: [],
             additions: 0,
             deletions: 0
           } = diff
  end

  test "empty before string produces added status" do
    diff = TextLineDiff.diff("", "new line\n", "new.txt")
    assert diff.status == :added
    assert diff.additions == 1
    assert diff.deletions == 0
  end

  test "empty after string produces deleted status" do
    diff = TextLineDiff.diff("old line\n", "", "deleted.txt")
    assert diff.status == :deleted
    assert diff.additions == 0
    assert diff.deletions == 1
  end

  test "both empty strings produce unchanged status" do
    diff = TextLineDiff.diff("", "", "empty.txt")
    assert diff.status == :unchanged
    assert diff.hunks == []
  end

  test "handles CRLF in before and after strings" do
    diff = TextLineDiff.diff("line 1\r\nline 2\r\n", "line 1\r\nline 2 changed\r\n", "crlf.txt")
    assert diff.status == :modified
    assert diff.additions == 1
    assert diff.deletions == 1
  end
end
