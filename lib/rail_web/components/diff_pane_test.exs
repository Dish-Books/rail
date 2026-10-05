defmodule RailWeb.Components.DiffPaneTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import Rail.Git.Utils.ParseDiff

  alias Rail.Pipeline.Schemas.DiffComment
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

  # Every line of a large branch is sent, so what each one costs beyond its code
  # is what decides how big the page is. The button that comments on it is most of that.
  test "a line's markup is little more than its code" do
    [file] =
      parse_diff(
        "diff --git a/a.ex b/a.ex\n--- a/a.ex\n+++ b/a.ex\n@@ -1,200 +1,200 @@\n" <>
          Enum.map_join(1..200, "", &" line #{&1}\n")
      )

    html = render_component(&DiffPane.diff_pane/1, files: [Map.put(file, :viewed?, false)])

    assert div(byte_size(html), 200) < 395
  end

  # A block that would not parse has no path, so two of them must still be two files.
  test "draws every file that has no path of its own", %{diff: diff} do
    unparsed = %{diff | path: "", display_path: "", rows: []}

    html =
      render_component(&DiffPane.diff_pane/1, files: [%{unparsed | digest: "first"}, %{unparsed | digest: "second"}])

    assert [_first, _second] = html |> Floki.parse_fragment!() |> Floki.find("[data-qa='diff_file_section']")
  end

  # git writes a file that became a symlink, or stopped being one, as two blocks
  # for the one path.
  test "draws both halves of a file that changed type", %{diff: diff} do
    html =
      (&DiffPane.diff_pane/1)
      |> render_component(
        files: [%{diff | status: :deleted, digest: "was_a_file"}, %{diff | status: :added, digest: "is_a_link"}]
      )
      |> Floki.parse_fragment!()

    assert [first, second] = Floki.find(html, "[data-qa='diff_file_section']")
    assert [_first_row, _second_row] = Floki.find(html, "[data-qa='diff-file-row']")
    refute Floki.attribute(first, "id") == Floki.attribute(second, "id")
  end

  test "says a file has been read, in the row and in the count", %{diff: diff} do
    html = render_component(&DiffPane.diff_pane/1, files: [Map.put(diff, :viewed?, true)])

    assert html =~ ~s(aria-pressed="true")
    assert html =~ "1/1"
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

  # A comment is never dropped: its file may only be out of this view.
  test "keeps comments on a file out of the view after the last file", %{diff: diff} do
    gone = %{
      %DiffComment{
        path: "lib/rail/feature.ex",
        line_kind: :added,
        line: 1,
        line_text: "def feature, do: :ok",
        filter: :branch,
        body: "Name this for what it does."
      }
      | id: "dcm_gone",
        path: "lib/gone.ex",
        body: "Still wanted."
    }

    html = render_component(&DiffPane.diff_pane/1, files: [diff], comments: [gone])

    assert [stray] = html |> Floki.parse_fragment!() |> Floki.find("[data-qa='diff_comment_stray_section']")
    assert Floki.text(stray) =~ "lib/gone.ex"
    assert Floki.text(stray) =~ "1 unsent"
    assert Floki.text(stray) =~ "Line 1 when you commented"
    assert Floki.text(stray) =~ "Still wanted."
    refute Floki.text(stray) =~ "Line changed"
    assert html =~ ~r/filter\.ex.*diff_comment_stray_section/s
  end

  test "a section holding only sent comments counts nothing unsent", %{diff: diff} do
    gone = %DiffComment{
      id: "dcm_gone_sent",
      path: "lib/gone.ex",
      line_kind: :added,
      line: 1,
      line_text: "def feature, do: :ok",
      filter: :branch,
      body: "Already sent.",
      status: :sent
    }

    html = render_component(&DiffPane.diff_pane/1, files: [diff], comments: [gone])

    assert [stray] = html |> Floki.parse_fragment!() |> Floki.find("[data-qa='diff_comment_stray_section']")
    assert Floki.text(stray) =~ "Already sent."
    refute Floki.text(stray) =~ "unsent"
  end

  test "has no such section while every comment's file is in view", %{diff: diff} do
    here = %{
      %DiffComment{
        path: "lib/rail/feature.ex",
        line_kind: :added,
        line: 1,
        line_text: "def feature, do: :ok",
        filter: :branch,
        body: "Name this for what it does."
      }
      | id: "dcm_here",
        path: diff.path
    }

    refute render_component(&DiffPane.diff_pane/1, files: [diff], comments: [here]) =~ "diff_comment_stray_section"
  end

  test "keeps them when the view has no files at all" do
    gone = %{
      %DiffComment{
        path: "lib/rail/feature.ex",
        line_kind: :added,
        line: 1,
        line_text: "def feature, do: :ok",
        filter: :branch,
        body: "Name this for what it does."
      }
      | id: "dcm_gone",
        path: "lib/gone.ex"
    }

    html = render_component(&DiffPane.diff_pane/1, files: [], comments: [gone], empty_message: "All committed.")

    assert html =~ "All committed."
    assert html =~ "diff_comment_stray_section"
  end
end
