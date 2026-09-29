defmodule RailWeb.Utils.CalculateDiffPaneTest do
  use ExUnit.Case, async: true

  import RailWeb.Utils.CalculateDiffPane

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
        scroll_to: nil
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
end
