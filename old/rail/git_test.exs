defmodule Rail.GitTest do
  use Rail.DataCase, async: true

  alias Rail.Domain.Diff.FileDiff
  alias Rail.Git

  test "parse_unified_diff/1 delegates to UnifiedDiffParser" do
    raw = """
    diff --git a/a.txt b/a.txt
    --- a/a.txt
    +++ b/a.txt
    @@ -1,1 +1,1 @@
    -old
    +new
    """

    assert [%FileDiff{path: "a.txt", status: :modified}] = Git.parse_unified_diff(raw)
  end

  test "diff_text/3 delegates to TextLineDiff" do
    assert %FileDiff{path: "test.txt", status: :modified, additions: 1, deletions: 1} =
             Git.diff_text("hello\n", "world\n", "test.txt")
  end
end
