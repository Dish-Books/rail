defmodule Rail.Git.Utils.ParseDiffTest do
  use ExUnit.Case, async: true

  import Rail.Git.Utils.ParseDiff

  test "nothing to parse is no files" do
    assert parse_diff(nil) == []
    assert parse_diff("") == []
    assert parse_diff("   \n\n  ") == []
  end

  test "a new file is every line added" do
    raw = """
    diff --git a/lib/new_file.ex b/lib/new_file.ex
    new file mode 100644
    index 0000000..abcdef1
    --- /dev/null
    +++ b/lib/new_file.ex
    @@ -0,0 +1,2 @@
    +defmodule NewFile do
    +end
    """

    assert [%{path: "lib/new_file.ex", status: :added, additions: 2, deletions: 0} = file] = parse_diff(raw)

    assert [
             %{kind: :hunk_header, text: "@@ -0,0 +1,2 @@"},
             %{kind: :line, line_kind: :added, new_line: 1, old_line: nil, text: "defmodule NewFile do", index: 0},
             %{kind: :line, line_kind: :added, new_line: 2, index: 1}
           ] = file.rows
  end

  test "a deleted file is every line removed" do
    raw = """
    diff --git a/lib/gone.ex b/lib/gone.ex
    deleted file mode 100644
    --- a/lib/gone.ex
    +++ /dev/null
    @@ -1,1 +0,0 @@
    -defmodule Gone do
    """

    assert [%{path: "lib/gone.ex", status: :deleted, additions: 0, deletions: 1}] = parse_diff(raw)
  end

  test "a renamed file names both sides" do
    raw = """
    diff --git a/lib/old.ex b/lib/new.ex
    similarity index 100%
    rename from lib/old.ex
    rename to lib/new.ex
    """

    assert [%{path: "lib/new.ex", display_path: "lib/old.ex → lib/new.ex", status: :renamed}] = parse_diff(raw)
  end

  test "context, additions and deletions carry the line numbers they land on" do
    raw = """
    diff --git a/lib/mixed.ex b/lib/mixed.ex
    --- a/lib/mixed.ex
    +++ b/lib/mixed.ex
    @@ -1,3 +1,3 @@
     one
    -two
    +TWO
    """

    assert [%{additions: 1, deletions: 1} = file] = parse_diff(raw)

    assert [
             %{kind: :hunk_header},
             %{line_kind: :context, old_line: 1, new_line: 1, text: "one"},
             %{line_kind: :deleted, old_line: 2, new_line: nil, text: "two"},
             %{line_kind: :added, old_line: nil, new_line: 2, text: "TWO"}
           ] = file.rows
  end

  test "a blank context line and a no-newline marker are read as git writes them" do
    raw =
      "diff --git a/lib/blank.ex b/lib/blank.ex\n" <>
        "--- a/lib/blank.ex\n+++ b/lib/blank.ex\n@@ -1,3 +1,3 @@\n one\n\n+two\n\\ No newline at end of file\n"

    assert [file] = parse_diff(raw)

    assert [
             %{kind: :hunk_header},
             %{line_kind: :context, text: "one"},
             %{line_kind: :context, text: ""},
             %{line_kind: :added, text: "two"}
           ] = file.rows
  end

  test "a line with no marker at all is read as context" do
    raw = "diff --git a/lib/odd.ex b/lib/odd.ex\n--- a/lib/odd.ex\n+++ b/lib/odd.ex\n@@ -1,1 +1,1 @@\nbare line\n"

    assert [%{rows: [%{kind: :hunk_header}, %{line_kind: :context, text: "bare line"}]}] = parse_diff(raw)
  end

  test "the gap between two hunks carries what it would take to fill it" do
    raw = """
    diff --git a/lib/wide.ex b/lib/wide.ex
    --- a/lib/wide.ex
    +++ b/lib/wide.ex
    @@ -1,1 +1,1 @@
    +first
    @@ -20,1 +20,1 @@
    +later
    """

    assert [%{rows: rows}] = parse_diff(raw)

    assert %{
             kind: :gap,
             key: "lib/wide.ex:0",
             path: "lib/wide.ex",
             gap_index: 0,
             start_line: 2,
             end_line: 19,
             old_start_line: 2,
             count: 18
           } = Enum.at(rows, 2)
  end

  test "hunks that meet leave no gap between them" do
    raw = """
    diff --git a/lib/tight.ex b/lib/tight.ex
    --- a/lib/tight.ex
    +++ b/lib/tight.ex
    @@ -1,1 +1,1 @@
    +first
    @@ -2,1 +2,1 @@
    +second
    """

    assert [%{rows: rows}] = parse_diff(raw)
    refute Enum.any?(rows, &(&1.kind == :gap))
  end

  test "a binary file stands in for itself" do
    raw = """
    diff --git a/assets/logo.png b/assets/logo.png
    Binary files a/assets/logo.png and b/assets/logo.png differ
    """

    assert [%{path: "assets/logo.png", binary?: true, rows: [%{kind: :binary}]}] = parse_diff(raw)
  end

  test "a single-sided binary notice still names the file" do
    raw = """
    diff --git a/assets/logo.png b/assets/logo.png
    Binary file assets/logo.png differs
    """

    assert [%{path: "assets/logo.png", binary?: true}] = parse_diff(raw)
  end

  test "paths come off the diff --git line when there are no --- and +++ headers" do
    assert [%{path: "lib/headerless.ex"}] =
             parse_diff("diff --git a/lib/headerless.ex b/lib/headerless.ex\nold mode 100644\n")
  end

  test "a quoted path with spaces is unquoted" do
    assert [%{path: "lib/with space.ex"}] =
             parse_diff(~s(diff --git "a/lib/with space.ex" "b/lib/with space.ex"\nold mode 100644\n))
  end

  test "an escape inside a quoted path is read back" do
    assert [%{path: ~S(lib/with"quote.ex)}] =
             parse_diff(~S(diff --git "a/lib/with\"quote.ex" "b/lib/with\"quote.ex") <> "\nold mode 100644\n")
  end

  test "a diff --git line it cannot split leaves the paths unknown" do
    assert [%{path: ""}] = parse_diff("diff --git a/one b/two c/three\nold mode 100644\n")
  end

  test "several files come back in the order the diff wrote them" do
    raw = """
    diff --git a/lib/first.ex b/lib/first.ex
    --- a/lib/first.ex
    +++ b/lib/first.ex
    @@ -1,1 +1,1 @@
    +one
    diff --git a/lib/second.ex b/lib/second.ex
    --- a/lib/second.ex
    +++ b/lib/second.ex
    @@ -1,1 +1,1 @@
    +two
    """

    assert [%{path: "lib/first.ex"}, %{path: "lib/second.ex"}] = parse_diff(raw)
  end

  # The digest is what a viewed mark is pinned to, so it has to ignore what a
  # rebase rewrites and notice what a code change does.
  test "the digest ignores index lines and follows the hunks" do
    with_index = """
    diff --git a/lib/x.ex b/lib/x.ex
    index 1111111..2222222 100644
    --- a/lib/x.ex
    +++ b/lib/x.ex
    @@ -1,1 +1,1 @@
    +one
    """

    rebased = String.replace(with_index, "index 1111111..2222222 100644", "index 3333333..4444444 100644")
    changed = String.replace(with_index, "+one", "+two")

    assert [%{digest: digest}] = parse_diff(with_index)
    assert [%{digest: ^digest}] = parse_diff(rebased)
    refute [%{digest: digest}] == parse_diff(changed)
  end

  test "carriage returns are not part of the lines" do
    assert [%{rows: [%{kind: :hunk_header}, %{text: "one"}]}] =
             parse_diff(
               "diff --git a/lib/crlf.ex b/lib/crlf.ex\r\n--- a/lib/crlf.ex\r\n+++ b/lib/crlf.ex\r\n@@ -1,1 +1,1 @@\r\n+one\r\n"
             )
  end

  test "a hunk header it cannot read is dropped rather than taking the file with it" do
    raw = """
    diff --git a/lib/bad.ex b/lib/bad.ex
    --- a/lib/bad.ex
    +++ b/lib/bad.ex
    @@ nonsense @@
    +one
    """

    assert [%{path: "lib/bad.ex", rows: []}] = parse_diff(raw)
  end

  test "a quoted path in the file headers is unquoted" do
    raw =
      ~s(diff --git a/lib/with space.ex b/lib/with space.ex\n) <>
        ~s(--- "a/lib/with space.ex"\n+++ "b/lib/with space.ex"\n@@ -1,1 +1,1 @@\n+one\n)

    assert [%{path: "lib/with space.ex"}] = parse_diff(raw)
  end

  test "a binary patch git wrote longhand is still a binary file" do
    raw = """
    diff --git a/assets/logo.png b/assets/logo.png
    GIT binary patch
    literal 120
    """

    assert [%{path: "assets/logo.png", binary?: true, rows: [%{kind: :binary}]}] = parse_diff(raw)
  end

  test "binary notices with no paths in them leave the diff --git line to say" do
    both = "diff --git a/a.png b/b.png\nBinary files differ\n"
    one = "diff --git a/a.png b/b.png\nBinary file a.png\n"

    assert [%{path: "b.png", binary?: true}] = parse_diff(both)
    assert [%{path: "b.png", binary?: true}] = parse_diff(one)
  end

  test "a binary notice whose paths carry no a/ or b/ prefix is taken as written" do
    raw = "diff --git a/old.png b/new.png\nBinary files old.png and new.png differ\n"

    assert [%{display_path: "old.png → new.png"}] = parse_diff(raw)
  end

  test "a file header with no a/ prefix on it is taken as written" do
    raw = "diff --git a/x.ex b/x.ex\n--- x.ex\n+++ b/x.ex\n@@ -1,1 +1,1 @@\n+one\n"

    assert [%{path: "x.ex", display_path: "x.ex"}] = parse_diff(raw)
  end

  test "a half-quoted diff --git line leaves the paths unknown" do
    assert [%{path: ""}] = parse_diff(~s(diff --git "a/one" b/two\nold mode 100644\n))
  end
end
