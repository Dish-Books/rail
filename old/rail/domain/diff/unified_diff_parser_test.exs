defmodule Rail.Domain.Diff.UnifiedDiffParserTest do
  use Rail.DataCase, async: true

  alias Rail.Domain.Diff.DiffHunk
  alias Rail.Domain.Diff.DiffLine
  alias Rail.Domain.Diff.FileDiff
  alias Rail.Domain.Diff.UnifiedDiffParser

  test "parses empty diff string to empty list" do
    assert UnifiedDiffParser.parse("") == []
    assert UnifiedDiffParser.parse("   \n\n  ") == []
    assert UnifiedDiffParser.parse(nil) == []
  end

  test "parses file addition" do
    raw = """
    diff --git a/lib/new_file.ex b/lib/new_file.ex
    new file mode 100644
    index 0000000..abcdef1
    --- /dev/null
    +++ b/lib/new_file.ex
    @@ -0,0 +1,3 @@
    +defmodule NewFile do
    +  def hello, do: :world
    +end
    """

    assert [
             %FileDiff{
               path: "lib/new_file.ex",
               old_path: nil,
               new_path: "lib/new_file.ex",
               status: :added,
               is_binary: false,
               additions: 3,
               deletions: 0,
               hunks: [
                 %DiffHunk{
                   old_start: 0,
                   old_count: 0,
                   new_start: 1,
                   new_count: 3,
                   lines: [
                     %DiffLine{
                       kind: :added,
                       old_line_number: nil,
                       new_line_number: 1,
                       text: "defmodule NewFile do"
                     },
                     %DiffLine{
                       kind: :added,
                       old_line_number: nil,
                       new_line_number: 2,
                       text: "  def hello, do: :world"
                     },
                     %DiffLine{
                       kind: :added,
                       old_line_number: nil,
                       new_line_number: 3,
                       text: "end"
                     }
                   ]
                 }
               ]
             }
           ] = UnifiedDiffParser.parse(raw)
  end

  test "parses file modification" do
    raw = """
    diff --git a/lib/foo.ex b/lib/foo.ex
    index 1111111..2222222 100644
    --- a/lib/foo.ex
    +++ b/lib/foo.ex
    @@ -10,5 +10,6 @@ def calculate do
       x = 1
    -  y = 2
    +  y = 3
    +  z = 4
       x + y
     end
    """

    assert [
             %FileDiff{
               path: "lib/foo.ex",
               status: :modified,
               additions: 2,
               deletions: 1,
               hunks: [
                 %DiffHunk{
                   heading: "def calculate do",
                   section_heading: "def calculate do",
                   old_start: 10,
                   old_count: 5,
                   new_start: 10,
                   new_count: 6,
                   lines: lines
                 }
               ]
             }
           ] = UnifiedDiffParser.parse(raw)

    assert length(lines) == 6
  end

  test "parses file deletion" do
    raw = """
    diff --git a/lib/obsolete.ex b/lib/obsolete.ex
    deleted file mode 100644
    index 2222222..0000000
    --- a/lib/obsolete.ex
    +++ /dev/null
    @@ -1,2 +0,0 @@
    -defmodule Obsolete do
    -end
    """

    assert [
             %FileDiff{
               path: "lib/obsolete.ex",
               old_path: "lib/obsolete.ex",
               new_path: nil,
               status: :deleted,
               additions: 0,
               deletions: 2,
               is_binary: false
             }
           ] = UnifiedDiffParser.parse(raw)
  end

  test "parses file rename without edits (100% similarity)" do
    raw = """
    diff --git a/lib/old_name.ex b/lib/new_name.ex
    similarity index 100%
    rename from lib/old_name.ex
    rename to lib/new_name.ex
    """

    assert [
             %FileDiff{
               path: "lib/new_name.ex",
               old_path: "lib/old_name.ex",
               new_path: "lib/new_name.ex",
               display_path: "lib/old_name.ex → lib/new_name.ex",
               is_renamed: true,
               status: :renamed,
               additions: 0,
               deletions: 0,
               hunks: []
             }
           ] = UnifiedDiffParser.parse(raw)
  end

  test "parses file rename with edits" do
    raw = """
    diff --git a/lib/old_widget.ex b/lib/new_widget.ex
    similarity index 85%
    rename from lib/old_widget.ex
    rename to lib/new_widget.ex
    index aaaaaaa..bbbbbbb 100644
    --- a/lib/old_widget.ex
    +++ b/lib/new_widget.ex
    @@ -1,3 +1,3 @@
    -defmodule OldWidget do
    +defmodule NewWidget do
    """

    assert [
             %FileDiff{
               path: "lib/new_widget.ex",
               old_path: "lib/old_widget.ex",
               new_path: "lib/new_widget.ex",
               display_path: "lib/old_widget.ex → lib/new_widget.ex",
               is_renamed: true,
               status: :renamed,
               additions: 1,
               deletions: 1,
               hunks: [
                 %DiffHunk{
                   lines: [
                     %DiffLine{kind: :deleted, text: "defmodule OldWidget do"},
                     %DiffLine{kind: :added, text: "defmodule NewWidget do"}
                   ]
                 }
               ]
             }
           ] = UnifiedDiffParser.parse(raw)
  end

  test "parses binary files with 'Binary files ... differ'" do
    raw = """
    diff --git a/assets/icon.png b/assets/icon.png
    index 1234567..89abcdef 100644
    Binary files a/assets/icon.png and b/assets/icon.png differ
    """

    assert [
             %FileDiff{
               path: "assets/icon.png",
               is_binary: true,
               additions: 0,
               deletions: 0,
               hunks: []
             }
           ] = UnifiedDiffParser.parse(raw)
  end

  test "parses synthetic untracked file diff" do
    raw = """
    diff --git a/scratch.txt b/scratch.txt
    new file (untracked)
    --- /dev/null
    +++ b/scratch.txt
    @@ -0,0 +1,2 @@
    +hello
    +world
    """

    assert [
             %FileDiff{
               path: "scratch.txt",
               status: :added,
               additions: 2,
               deletions: 0,
               hunks: [
                 %DiffHunk{
                   lines: [
                     %DiffLine{kind: :added, text: "hello"},
                     %DiffLine{kind: :added, text: "world"}
                   ]
                 }
               ]
             }
           ] = UnifiedDiffParser.parse(raw)
  end

  test "parses synthetic untracked binary file" do
    raw = """
    diff --git a/photo.jpg b/photo.jpg
    new file (untracked)
    Binary file photo.jpg differs
    """

    assert [
             %FileDiff{
               path: "photo.jpg",
               is_binary: true,
               status: :added
             }
           ] = UnifiedDiffParser.parse(raw)
  end

  test "parses paths with spaces" do
    raw = """
    diff --git "a/path with spaces/my file.ex" "b/path with spaces/my file.ex"
    index 1111111..2222222 100644
    --- "a/path with spaces/my file.ex"
    +++ "b/path with spaces/my file.ex"
    @@ -1,1 +1,1 @@
    -old
    +new
    """

    assert [
             %FileDiff{
               path: "path with spaces/my file.ex",
               additions: 1,
               deletions: 1
             }
           ] = UnifiedDiffParser.parse(raw)
  end

  test "parses multiple hunks with exact line numbers, omitted count, and no-newline marker" do
    raw = """
    diff --git a/lib/multi.ex b/lib/multi.ex
    index 1111111..2222222 100644
    --- a/lib/multi.ex
    +++ b/lib/multi.ex
    @@ -1 +1 @@
    -line1_old
    +line1_new
    @@ -10,6 +10,7 @@
     context_10
    -removed_11
    +added_11
    +added_12
     context_12
     context_13
     context_14
    \\ No newline at end of file
    """

    assert [
             %FileDiff{
               hunks: [
                 %DiffHunk{
                   old_start: 1,
                   old_count: 1,
                   new_start: 1,
                   new_count: 1,
                   lines: [
                     %DiffLine{kind: :deleted, old_line_number: 1, new_line_number: nil},
                     %DiffLine{kind: :added, old_line_number: nil, new_line_number: 1}
                   ]
                 },
                 %DiffHunk{
                   old_start: 10,
                   old_count: 6,
                   new_start: 10,
                   new_count: 7,
                   lines: [
                     %DiffLine{kind: :context, old_line_number: 10, new_line_number: 10},
                     %DiffLine{kind: :deleted, old_line_number: 11, new_line_number: nil},
                     %DiffLine{kind: :added, old_line_number: nil, new_line_number: 11},
                     %DiffLine{kind: :added, old_line_number: nil, new_line_number: 12},
                     %DiffLine{kind: :context, old_line_number: 12, new_line_number: 13},
                     %DiffLine{kind: :context, old_line_number: 13, new_line_number: 14},
                     %DiffLine{kind: :context, old_line_number: 14, new_line_number: 15}
                   ]
                 }
               ]
             }
           ] = UnifiedDiffParser.parse(raw)
  end

  test "digest is stable across rebases that rewrite index blob ids" do
    diff1 = """
    diff --git a/lib/file.ex b/lib/file.ex
    index 1111111..2222222 100644
    --- a/lib/file.ex
    +++ b/lib/file.ex
    @@ -1,3 +1,3 @@
    -old line
    +new line
     context
    """

    diff2 = """
    diff --git a/lib/file.ex b/lib/file.ex
    index 3333333..4444444 100644
    --- a/lib/file.ex
    +++ b/lib/file.ex
    @@ -1,3 +1,3 @@
    -old line
    +new line
     context
    """

    diff_changed = """
    diff --git a/lib/file.ex b/lib/file.ex
    index 1111111..2222222 100644
    --- a/lib/file.ex
    +++ b/lib/file.ex
    @@ -1,3 +1,3 @@
    -old line
    +different line
     context
    """

    [file1] = UnifiedDiffParser.parse(diff1)
    [file2] = UnifiedDiffParser.parse(diff2)
    [file_changed] = UnifiedDiffParser.parse(diff_changed)

    assert file1.digest == file2.digest
    assert file1.digest != file_changed.digest
  end

  test "degrades gracefully on unparseable block without throwing" do
    raw = """
    some unrecognized preamble junk
    diff --git corrupted block
    ??? unexpected content
    """

    parsed = UnifiedDiffParser.parse(raw)
    assert parsed != []
    [first | _rest] = parsed
    assert byte_size(first.digest) == 64
    assert first.status == :modified
  end

  test "handles empty context line as bare empty line" do
    raw = """
    diff --git a/lib/empty_ctx.ex b/lib/empty_ctx.ex
    --- a/lib/empty_ctx.ex
    +++ b/lib/empty_ctx.ex
    @@ -1,3 +1,3 @@
     start

     end
    """

    [file] = UnifiedDiffParser.parse(raw)
    [hunk] = file.hunks
    assert length(hunk.lines) == 3
    middle_line = Enum.at(hunk.lines, 1)
    assert middle_line.kind == :context
    assert middle_line.text == ""
  end

  test "handles unrecognized lines inside hunk by degrading to context" do
    raw = """
    diff --git a/lib/unknown.ex b/lib/unknown.ex
    --- a/lib/unknown.ex
    +++ b/lib/unknown.ex
    @@ -1,1 +1,1 @@
    custom diff line without standard prefix
    """

    [file] = UnifiedDiffParser.parse(raw)
    [hunk] = file.hunks
    [line] = hunk.lines
    assert line.kind == :context
    assert line.text == "custom diff line without standard prefix"
  end

  test "parses GIT binary patch" do
    raw = """
    diff --git a/file.bin b/file.bin
    GIT binary patch
    literal 12
    zc$@*
    """

    [file] = UnifiedDiffParser.parse(raw)
    assert file.is_binary == true
  end

  test "parses diff with CRLF newlines" do
    raw =
      "diff --git a/file.ex b/file.ex\r\nnew file mode 100644\r\n--- /dev/null\r\n+++ b/file.ex\r\n@@ -0,0 +1,1 @@\r\n+crlf line\r\n"

    [file] = UnifiedDiffParser.parse(raw)
    assert file.status == :added
    assert file.additions == 1
  end

  test "parses diff without trailing newline" do
    raw = "diff --git a/file.ex b/file.ex\nnew file mode 100644\n--- /dev/null\n+++ b/file.ex\n@@ -0,0 +1,1 @@\n+line"
    [file] = UnifiedDiffParser.parse(raw)
    assert file.status == :added
    assert file.additions == 1
  end

  test "extracts fallback paths from diff --git when --- and +++ are missing" do
    # Quoted
    raw_quoted = ~s(diff --git "a/my space/file.ex" "b/my space/file.ex"\nold mode 100644\nnew mode 100755\n)
    [file_quoted] = UnifiedDiffParser.parse(raw_quoted)
    assert file_quoted.path == "my space/file.ex"

    # Unquoted
    raw_unquoted = "diff --git a/plain.ex b/plain.ex\nold mode 100644\nnew mode 100755\n"
    [file_unquoted] = UnifiedDiffParser.parse(raw_unquoted)
    assert file_unquoted.path == "plain.ex"

    # Malformed / unrecognized remainder
    raw_invalid = "diff --git invalid_remainder_no_parts\nold mode 100644\nnew mode 100755\n"
    [file_invalid] = UnifiedDiffParser.parse(raw_invalid)
    assert file_invalid.path == ""

    # Malformed quoted remainder starting with quote but not matching regex
    raw_invalid_quote = "diff --git \"only_one_quote\nold mode 100644\nnew mode 100755\n"
    [file_invalid_quote] = UnifiedDiffParser.parse(raw_invalid_quote)
    assert file_invalid_quote.path == ""
  end

  test "handles clean_path without standard a/ or b/ prefix" do
    raw = """
    diff --git custom/path.ex custom/path.ex
    --- custom/path.ex
    +++ custom/path.ex
    @@ -1,1 +1,1 @@
    -old
    +new
    """

    [file] = UnifiedDiffParser.parse(raw)
    assert file.old_path == "custom/path.ex"
    assert file.new_path == "custom/path.ex"
  end

  test "skips malformed hunk headers" do
    raw = """
    diff --git a/lib/test.ex b/lib/test.ex
    --- a/lib/test.ex
    +++ b/lib/test.ex
    @@ malformed hunk @@
    some text
    @@ -1,1 +1,1 @@
    -old
    +new
    """

    [file] = UnifiedDiffParser.parse(raw)
    assert length(file.hunks) == 1
    assert file.additions == 1
    assert file.deletions == 1
  end

  test "handles binary file marker without standard diff format" do
    raw = """
    diff --git a/lib/bin.dat b/lib/bin.dat
    Binary files something unrecognized
    Binary file something else unrecognized
    """

    [file] = UnifiedDiffParser.parse(raw)
    assert file.is_binary == true
  end
end
