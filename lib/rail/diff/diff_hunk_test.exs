defmodule Rail.Diff.DiffHunkTest do
  use Rail.DataCase, async: true

  alias Rail.Diff.DiffHunk

  test "new/1 delegates to Rail.Domain.Diff.DiffHunk" do
    hunk = DiffHunk.new(header: "@@ -1,3 +1,3 @@", old_start: 1, new_start: 1)
    assert hunk.header == "@@ -1,3 +1,3 @@"
  end
end
