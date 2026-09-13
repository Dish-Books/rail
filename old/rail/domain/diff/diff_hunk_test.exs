defmodule Rail.Domain.Diff.DiffHunkTest do
  use Rail.DataCase, async: true

  alias Rail.Domain.Diff.DiffHunk
  alias Rail.Domain.Diff.DiffLine

  test "new/1 creates a DiffHunk struct with default counts and empty lines" do
    assert %DiffHunk{
             header: "@@ -1 +1 @@",
             old_start: 1,
             old_count: 1,
             new_start: 1,
             new_count: 1,
             heading: nil,
             section_heading: nil,
             lines: []
           } =
             DiffHunk.new(%{
               header: "@@ -1 +1 @@",
               old_start: 1,
               new_start: 1
             })
  end

  test "new/1 accepts keyword list and sets heading on both heading and section_heading" do
    line = %DiffLine{kind: :context, old_line_number: 10, new_line_number: 10, text: "def test"}

    assert %DiffHunk{
             header: "@@ -10,5 +10,6 @@ def test",
             old_start: 10,
             old_count: 5,
             new_start: 10,
             new_count: 6,
             heading: "def test",
             section_heading: "def test",
             lines: [^line]
           } =
             DiffHunk.new(
               header: "@@ -10,5 +10,6 @@ def test",
               old_start: 10,
               old_count: 5,
               new_start: 10,
               new_count: 6,
               heading: "def test",
               lines: [line]
             )
  end

  test "new/1 sets section_heading when provided via section_heading key" do
    assert %DiffHunk{
             heading: "calculate()",
             section_heading: "calculate()"
           } =
             DiffHunk.new(%{
               header: "@@ -1,2 +1,2 @@ calculate()",
               old_start: 1,
               new_start: 1,
               section_heading: "calculate()"
             })
  end
end
