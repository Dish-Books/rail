defmodule RailWeb.Utils.CalculateDiffPaneTest do
  use ExUnit.Case, async: true

  import RailWeb.Utils.CalculateDiffPane

  alias Rail.Pipeline.Schemas.DiffComment

  setup do
    diff = %{
      path: "lib/filter.ex",
      display_path: "lib/filter.ex",
      status: :modified,
      digest: "filter_digest",
      additions: 2,
      deletions: 1,
      viewed?: false,
      rows: [%{kind: :gap, key: "lib/filter.ex:0"}]
    }

    %{
      diff: diff,
      assigns: %{
        files: [diff],
        query: "",
        target: nil,
        collapsed: [],
        expanded_gaps: %{},
        show_file_tree: true,
        filter: :branch,
        selected_file: nil,
        empty_message: "Nothing yet.",
        scroll_to: nil,
        comments: [],
        open_comments: [],
        comment_list: :files,
        selected_comment: nil,
        draft: nil,
        engineer_running?: false
      }
    }
  end

  test "a file goes by its path while no other file has it", %{assigns: assigns} do
    assert %{frame: %{sections: ["lib/filter.ex"]}, sections: [{"lib/filter.ex", _section}]} =
             calculate_diff_pane(assigns)
  end

  # A file that changed type is two blocks for one path, and one that would not
  # parse has no path at all, so each takes its digest.
  test "a file whose path is not its alone goes by its digest", %{assigns: assigns, diff: diff} do
    halves = [%{diff | digest: "was_a_file"}, %{diff | digest: "is_a_link"}]
    unparsed = [%{diff | path: "", digest: "unparsed"}]

    assert %{frame: %{sections: ["was_a_file", "is_a_link", "unparsed"]}, tree: %{rows: rows}} =
             calculate_diff_pane(%{assigns | files: halves ++ unparsed})

    assert Enum.map(rows, & &1.id) == ["was_a_file", "is_a_link", "unparsed"]
  end

  test "a file carries its own fold and only its own opened gaps", %{assigns: assigns, diff: diff} do
    gaps = %{"lib/filter.ex:0" => [%{text: "between", html: nil}], "mix.exs:0" => [%{text: "other", html: nil}]}

    assert %{sections: [{_id, %{collapsed?: true, expanded_gaps: expanded}}]} =
             calculate_diff_pane(%{assigns | collapsed: [diff.path], expanded_gaps: gaps})

    assert Map.keys(expanded) == ["lib/filter.ex:0"]
  end

  test "counts the whole diff while showing only what the query leaves", %{assigns: assigns, diff: diff} do
    other = %{diff | path: "mix.exs", display_path: "mix.exs", viewed?: true}

    assert %{toolbar: %{additions: 4, deletions: 2, viewed: 1, total: 2}, tree: %{label: "2 files changed", rows: [_one]}} =
             calculate_diff_pane(%{assigns | files: [diff, other], query: "MIX"})
  end

  test "says so when the query leaves nothing", %{assigns: assigns} do
    assert %{frame: %{no_match: "nothing-like-this", sections: []}} =
             calculate_diff_pane(%{assigns | query: "nothing-like-this"})
  end

  test "has no file list and says so when there are no files", %{assigns: assigns} do
    assert %{frame: %{empty_message: "Nothing yet."}, tree: nil, sections: []} =
             calculate_diff_pane(%{assigns | files: []})
  end

  test "marks the file the reader selected in the list", %{assigns: assigns, diff: diff} do
    assert %{tree: %{rows: [%{selected?: true}]}} = calculate_diff_pane(%{assigns | selected_file: diff.path})
  end

  describe "comments" do
    setup %{diff: diff} do
      header = %{kind: :hunk_header, text: "@@ -1,3 +1,3 @@"}
      opening = %{kind: :line, line_kind: :context, old_line: 1, new_line: 1, text: "defmodule Filter do"}
      removed = %{kind: :line, line_kind: :deleted, old_line: 2, new_line: nil, text: "  def filter(list), do: list"}
      added = %{kind: :line, line_kind: :added, old_line: nil, new_line: 2, text: "  def filter(list, v), do: list"}
      closing = %{kind: :line, line_kind: :context, old_line: 3, new_line: 3, text: "end"}

      comment = fn attrs ->
        struct!(
          %{
            %DiffComment{
              path: "lib/rail/feature.ex",
              line_kind: :added,
              line: 1,
              line_text: "def feature, do: :ok",
              filter: :branch,
              body: "Name this for what it does."
            }
            | id: UXID.generate!(prefix: "dcm"),
              path: diff.path
          },
          attrs
        )
      end

      %{
        diff: %{diff | rows: [header, opening, removed, added, closing]},
        rows: %{header: header, opening: opening, removed: removed, added: added, closing: closing},
        comment: comment
      }
    end

    test "a comment sits under the line it was written on, whatever kind of line", %{
      assigns: assigns,
      diff: diff,
      rows: rows,
      comment: comment
    } do
      on_removed = comment.(line_kind: :deleted, line: 2, line_text: rows.removed.text)
      on_added = comment.(line_kind: :added, line: 2, line_text: rows.added.text)
      on_closing = comment.(line_kind: :context, line: 3, line_text: "end")

      segments = [
        %{rows: [rows.header, rows.opening, rows.removed], comments: [on_removed], draft: nil},
        %{rows: [rows.added], comments: [on_added], draft: nil},
        %{rows: [rows.closing], comments: [on_closing], draft: nil}
      ]

      assert %{sections: [{_id, %{segments: ^segments, lifted: [], changed_count: 0, unsent: 3}}]} =
               calculate_diff_pane(%{assigns | files: [diff], comments: [on_removed, on_added, on_closing]})
    end

    # An added line the engineer has since committed reads as unchanged in the
    # uncommitted view, and it is still the same line.
    test "a comment on an added line stays with it once it reads as unchanged", %{
      assigns: assigns,
      diff: diff,
      rows: %{closing: closing},
      comment: comment
    } do
      on_closing = comment.(line_kind: :added, line: 3, line_text: "end")

      assert %{
               sections: [
                 {_id, %{segments: [%{rows: [_header, _opening, _removed, _added, ^closing], comments: [^on_closing]}]}}
               ]
             } =
               calculate_diff_pane(%{assigns | files: [diff], comments: [on_closing]})
    end

    test "a comment whose line reads differently now is lifted and says so", %{
      assigns: assigns,
      diff: diff,
      comment: comment
    } do
      rewritten = comment.(line_kind: :added, line: 2, line_text: "  def filter(list), do: :before")
      out_of_view = comment.(line_kind: :added, line: 40, line_text: "  # far below")

      assert %{sections: [{_id, section}]} =
               calculate_diff_pane(%{assigns | files: [diff], comments: [rewritten, out_of_view]})

      assert %{lifted: [{^rewritten, true}, {^out_of_view, false}], changed_count: 1, unsent: 2} = section
      assert [%{comments: [], draft: nil}] = section.segments
    end

    # Old-side numbers are counted from a different base in each view.
    test "a comment on a removed line stays in the view it was written in", %{
      assigns: assigns,
      diff: diff,
      rows: rows,
      comment: comment
    } do
      elsewhere = comment.(line_kind: :deleted, line: 2, line_text: rows.removed.text, filter: :uncommitted)

      assert %{sections: [{_id, %{lifted: [{^elsewhere, false}], changed_count: 0}}]} =
               calculate_diff_pane(%{assigns | files: [diff], comments: [elsewhere]})
    end

    test "a comment on a file out of the view is kept after the last file, one the query hides is not", %{
      assigns: assigns,
      diff: diff,
      comment: comment
    } do
      hidden = %{diff | path: "mix.exs", display_path: "mix.exs", digest: "mix_digest"}
      on_gone = comment.(path: "lib/gone.ex")
      on_hidden = comment.(path: "mix.exs")

      assert %{frame: %{stray: [{"lib/gone.ex", [{^on_gone, false}]}], sections: ["lib/filter.ex"]}} =
               calculate_diff_pane(%{assigns | files: [diff, hidden], query: "filter", comments: [on_gone, on_hidden]})
    end

    test "counts every unsent comment, and each file its own", %{assigns: assigns, diff: diff, comment: comment} do
      other = %{diff | path: "mix.exs", display_path: "mix.exs", digest: "mix_digest"}

      comments = [
        comment.(path: "lib/gone.ex"),
        comment.([]),
        comment.(status: :sent),
        comment.(path: "mix.exs"),
        comment.(path: "mix.exs"),
        comment.(path: "mix.exs", status: :resolved)
      ]

      assert %{
               toolbar: %{unsent: 4, engineer_running?: true},
               tree: %{rows: [%{unsent: 1}, %{unsent: 2}]},
               sections: [{_filter, %{unsent: 1}}, {_mix, %{unsent: 2}}]
             } = calculate_diff_pane(%{assigns | files: [diff, other], comments: comments, engineer_running?: true})
    end

    # Line changed is said of every comment, but the notice is about what Send sends.
    test "a sent or resolved comment whose line changed is lifted, and only unsent ones are in the notice", %{
      assigns: assigns,
      diff: diff,
      comment: comment
    } do
      sent = comment.(line_kind: :added, line: 2, line_text: "  was here", status: :sent)
      resolved = comment.(line_kind: :added, line: 2, line_text: "  was here", status: :resolved)

      assert %{sections: [{_id, %{lifted: [{^sent, true}, {^resolved, true}], changed_count: 0, unsent: 0}}]} =
               calculate_diff_pane(%{assigns | files: [diff], comments: [sent, resolved]})

      unsent = comment.(line_kind: :added, line: 2, line_text: "  was here")

      assert %{sections: [{_id, %{changed_count: 1}}]} =
               calculate_diff_pane(%{assigns | files: [diff], comments: [sent, unsent]})
    end

    test "a resolved comment the reader unfolded says so, in its file or out of the view", %{
      assigns: assigns,
      diff: diff,
      rows: rows,
      comment: comment
    } do
      %{id: open_id} = open = comment.(line_kind: :context, line: 3, line_text: rows.closing.text, status: :resolved)
      folded = comment.(line_kind: :context, line: 3, line_text: rows.closing.text, status: :resolved)
      %{id: gone_id} = gone = comment.(path: "lib/gone.ex", status: :resolved)

      assert %{sections: [{_id, %{open: [^open_id]}}], frame: %{stray: [{"lib/gone.ex", [{^gone, true}]}]}} =
               calculate_diff_pane(%{
                 assigns
                 | files: [diff],
                   comments: [open, folded, gone],
                   open_comments: [open_id, gone_id]
               })
    end

    test "lists every comment under its state, leaving out a state with none", %{
      assigns: assigns,
      diff: diff,
      comment: comment
    } do
      %{id: selected_id} = unsent = comment.(line: 40)
      rewritten = comment.(line_kind: :added, line: 2, line_text: "  was here", status: :resolved)
      gone = comment.(path: "lib/gone.ex", status: :resolved)
      other = %{diff | path: "mix.exs", display_path: "mix.exs", digest: "mix_digest"}

      assert %{
               tree: %{
                 list: :comments,
                 file_count: 2,
                 comment_count: 3,
                 selected_comment: ^selected_id,
                 groups: [
                   %{status: :unsent, label: "Not sent", rows: [%{comment: ^unsent, changed?: false}]},
                   %{
                     status: :resolved,
                     label: "Resolved",
                     rows: [%{comment: ^rewritten, changed?: true}, %{comment: ^gone, changed?: false}]
                   }
                 ]
               }
             } =
               calculate_diff_pane(%{
                 assigns
                 | files: [diff, other],
                   query: "mix",
                   comments: [unsent, rewritten, gone],
                   comment_list: :comments,
                   selected_comment: selected_id
               })
    end

    test "the comment being written sits under its line", %{assigns: assigns, diff: diff, rows: %{added: added}} do
      draft = %{path: diff.path, line_kind: :added, line: 2, line_text: added.text, filter: :branch}

      assert %{
               sections: [
                 {_id, %{segments: [%{rows: [_header, _opening, _removed, ^added], draft: ^draft}, %{draft: nil}]}}
               ]
             } =
               calculate_diff_pane(%{assigns | files: [diff], draft: draft})
    end

    test "the comment being written goes when its line does", %{assigns: assigns, diff: diff} do
      draft = %{path: diff.path, line_kind: :added, line: 2, line_text: "  gone since", filter: :branch}

      assert %{sections: [{_id, %{segments: [%{draft: nil}]}}]} =
               calculate_diff_pane(%{assigns | files: [diff], draft: draft})
    end
  end
end
