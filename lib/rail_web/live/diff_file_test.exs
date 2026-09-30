defmodule RailWeb.Live.DiffFileTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import Rail.Git.Utils.ParseDiff

  alias Rail.Pipeline.Schemas.DiffComment
  alias RailWeb.Live.DiffFile

  setup do
    [file] =
      parse_diff("""
      diff --git a/lib/rail/invoices/filter.ex b/lib/rail/invoices/filter.ex
      --- a/lib/rail/invoices/filter.ex
      +++ b/lib/rail/invoices/filter.ex
      @@ -1,2 +1,2 @@
       defmodule Filter do
      -  def filter(list), do: list
      +  def filter(list, vendor), do: Enum.filter(list, vendor)
      """)

    [header, opening, removed, added] = file.rows

    %{
      rows: %{header: header, opening: opening, removed: removed, added: added},
      section: %{
        id: file.path,
        target: nil,
        file: file,
        segments: [%{rows: file.rows, comments: [], draft: nil}],
        lifted: [],
        changed_count: 0,
        unsent: 0,
        viewed?: false,
        collapsed?: false,
        expanded_gaps: %{}
      }
    }
  end

  test "names the file and the directory it sits in, over its lines", %{section: section} do
    html = render_component(DiffFile, section)

    assert html =~ "lib/rail/invoices/"
    assert html =~ "filter.ex"
    assert html =~ ~s(data-kind="added")
  end

  test "names both sides of a renamed file", %{section: section} do
    [renamed] =
      parse_diff("diff --git a/lib/old_name.ex b/lib/new_name.ex\n--- a/lib/old_name.ex\n+++ b/lib/new_name.ex\n")

    assert render_component(DiffFile, %{section | file: renamed, segments: []}) =~ "lib/old_name.ex → lib/new_name.ex"
  end

  test "the caret that folds it says which file", %{section: section} do
    assert render_component(DiffFile, section) =~ ~s(aria-label="Fold lib/rail/invoices/filter.ex")
  end

  test "a collapsed file is only its header", %{section: section} do
    html = render_component(DiffFile, %{section | collapsed?: true})

    refute html =~ ~s(data-kind="added")
    assert html =~ "filter.ex"
  end

  test "says it has been read", %{section: section} do
    assert render_component(DiffFile, %{section | viewed?: true}) =~ ~s(aria-pressed="true")
  end

  test "calls out what became of a file the change did not only edit", %{section: section} do
    for {status, label} <- [added: "new file", deleted: "deleted", renamed: "renamed"] do
      assert render_component(DiffFile, %{section | file: %{section.file | status: status}}) =~ label
    end

    refute render_component(DiffFile, section) =~ "diff_status_badge"
  end

  describe "comments" do
    setup do
      %{comment: %{DiffComment.factory() | id: "dcm_on_removed", line_kind: :deleted, line: 2, body: "Keep this one."}}
    end

    test "counts its unsent comments in the header, folded or not", %{section: section} do
      for collapsed? <- [false, true] do
        html = render_component(DiffFile, %{section | unsent: 2, collapsed?: collapsed?})

        assert html |> Floki.parse_fragment!() |> Floki.find("[data-qa='diff_file_header']") |> Floki.text() =~
                 "2 unsent"
      end

      refute render_component(DiffFile, section) =~ "unsent"
    end

    test "draws a comment under the line it is on, not yet sent", %{section: section, rows: rows, comment: comment} do
      segments = [
        %{rows: [rows.header, rows.opening, rows.removed], comments: [comment], draft: nil},
        %{rows: [rows.added], comments: [], draft: nil}
      ]

      html = render_component(DiffFile, %{section | segments: segments, unsent: 1})

      assert html =~ ~r/def filter\(list\), do: list.*Not sent.*Keep this one\..*def filter\(list, vendor\)/s
      assert html =~ ~s(phx-click="remove_diff_comment")
      assert html =~ ~s(phx-value-id="dcm_on_removed")
      refute html =~ "Line changed"
    end

    test "offers a comment on each line it draws", %{section: section} do
      assert html = render_component(DiffFile, section)
      assert [_opening, _removed, _added] = html |> Floki.parse_fragment!() |> Floki.find("[data-qa='diff_comment_add']")
    end

    test "puts a comment whose line has changed first, saying it is still sent", %{
      section: section,
      comment: comment
    } do
      html = render_component(DiffFile, %{section | lifted: [{comment, true}], changed_count: 1, unsent: 1})

      assert html =~
               ~r/1 comment is on a line that has changed\..*It is still sent, quoting the line as you saw it\..*Line changed.*Removed line 2 when you commented.*def feature, do: :ok.*Keep this one\..*defmodule Filter do/s
    end

    test "says how many comments are on lines that have changed", %{section: section, comment: comment} do
      lifted = [{comment, true}, {%{comment | id: "dcm_other"}, true}]

      html = render_component(DiffFile, %{section | lifted: lifted, changed_count: 2, unsent: 2})

      assert html =~ "2 comments are on lines that have changed."
      assert html =~ "They are still sent, quoting the lines as you saw them."
    end

    test "a comment only out of view is lifted without saying its line changed", %{section: section, comment: comment} do
      html = render_component(DiffFile, %{section | lifted: [{comment, false}], unsent: 1})

      assert html =~ "Removed line 2 when you commented"
      refute html =~ "has changed"
      refute html =~ "Line changed"
    end

    test "opens the comment being written under its line", %{section: section, rows: rows} do
      draft = %{path: section.file.path, line_kind: :added, line: 2, line_text: rows.added.text, filter: :branch}
      segments = [%{rows: [rows.header, rows.opening, rows.removed, rows.added], comments: [], draft: draft}]

      html = render_component(DiffFile, %{section | segments: segments})

      assert html =~ ~r/def filter\(list, vendor\).*id="diff-comment-form"/s
      assert html =~ ~s(phx-submit="save_diff_comment")
      assert html =~ ~s(name="body")
      assert html =~ "Only you see this until you send it."
      assert html =~ ~s(phx-click="cancel_diff_comment")
      assert html =~ "Save comment"
    end
  end
end
