defmodule RailWeb.Utils.CalculateDiffPane do
  @moduledoc """
  What each part of the diff pane draws, split the way LiveView patches it.

  The browser redraws everything under whatever a patch touches, so the toolbar,
  the file list and each file are live components of their own. The pane draws
  itself whole only when its frame moves; the stage owning it compares these
  parts to send any other change to the part it moved.
  """

  @doc """
  The pane's `frame`, which only changes when files come or go or a comment's
  file leaves the view (`stray`), then the assigns of its `toolbar`, its file
  `tree` (`nil` while there are no files) and each of its `sections`, keyed by
  the id that file's component goes by. A section's rows come in `segments`, cut
  after each line with comments or the comment being written under it, and the
  comments that no longer have their line are `lifted` to the top of it.
  """
  def calculate_diff_pane(assigns) do
    %{files: files, query: query, target: target} = assigns
    visible = Enum.filter(files, &matches?(&1, query))
    comments = Enum.group_by(assigns.comments, & &1.path)

    shared =
      for {path, count} <- Enum.frequencies_by(files, & &1.path), count > 1 or path == "", into: MapSet.new(), do: path

    %{
      frame: %{
        sections: Enum.map(visible, &section_id(&1, shared)),
        empty_message: if(files == [], do: assigns.empty_message),
        no_match: if(files != [] and visible == [], do: query),
        scroll_to: assigns.scroll_to,
        stray: stray(comments, files)
      },
      toolbar: %{
        target: target,
        show_file_tree: assigns.show_file_tree,
        filter: assigns.filter,
        query: query,
        additions: Enum.sum_by(files, & &1.additions),
        deletions: Enum.sum_by(files, & &1.deletions),
        viewed: Enum.count(files, & &1.viewed?),
        total: length(files),
        unsent: length(assigns.comments),
        engineer_running?: assigns.engineer_running?
      },
      tree:
        if(files != [],
          do: %{
            target: target,
            show?: assigns.show_file_tree,
            label: files_changed(files),
            rows: Enum.map(visible, &tree_row(&1, shared, assigns.selected_file, comments))
          }
        ),
      sections: Enum.map(visible, &{section_id(&1, shared), section(&1, Map.get(comments, &1.path, []), assigns)})
    }
  end

  defp matches?(_file, ""), do: true
  defp matches?(file, query), do: String.contains?(String.downcase(file.path), String.downcase(query))

  defp files_changed([_one]), do: "1 file changed"
  defp files_changed(files), do: "#{length(files)} files changed"

  # A path keeps naming a file while its contents change, so its part is patched
  # rather than replaced. A path that is not one file's alone takes the digest:
  # a file that changed type is two blocks, and one that would not parse has none.
  defp section_id(%{path: path, digest: digest}, shared) do
    if MapSet.member?(shared, path), do: digest, else: path
  end

  # Only a file missing from the view entirely: one the query hides is still there.
  defp stray(comments, files) do
    paths = MapSet.new(files, & &1.path)

    comments |> Enum.reject(fn {path, _comments} -> MapSet.member?(paths, path) end) |> Enum.sort()
  end

  defp tree_row(file, shared, selected_file, comments) do
    %{
      id: section_id(file, shared),
      file: Map.drop(file, [:rows, :viewed?]),
      viewed?: file.viewed?,
      selected?: file.path == selected_file,
      unsent: length(Map.get(comments, file.path, []))
    }
  end

  defp section(file, comments, assigns) do
    gap_keys = for %{kind: :gap, key: key} <- file.rows, do: key
    draft = if assigns.draft && assigns.draft.path == file.path, do: assigns.draft
    {placed, lifted} = Enum.split_with(comments, &(anchor(&1, file.rows, assigns.filter) != nil))
    lifted = Enum.map(lifted, &{&1, changed?(&1, file.rows, assigns.filter)})

    %{
      target: assigns.target,
      file: Map.drop(file, [:rows, :viewed?]),
      segments: segments(file.rows, placed, draft, assigns.filter),
      lifted: lifted,
      changed_count: Enum.count(lifted, fn {_comment, changed?} -> changed? end),
      unsent: length(comments),
      viewed?: file.viewed?,
      collapsed?: file.path in assigns.collapsed,
      expanded_gaps: Map.take(assigns.expanded_gaps, gap_keys)
    }
  end

  # Rows with nothing under them stay in one run, so a file with no comments is
  # still one comprehension over its lines.
  defp segments([], _placed, _draft, _filter), do: []

  defp segments(rows, placed, draft, filter) do
    {done, current} =
      Enum.reduce(rows, {[], []}, fn row, {done, current} ->
        current = [row | current]
        under = Enum.filter(placed, &(anchor(&1, [row], filter) != nil))
        draft_here = if draft && anchor(draft, [row], filter), do: draft

        if under == [] and is_nil(draft_here),
          do: {done, current},
          else: {[%{rows: Enum.reverse(current), comments: under, draft: draft_here} | done], []}
      end)

    done = if current == [], do: done, else: [%{rows: Enum.reverse(current), comments: [], draft: nil} | done]

    Enum.reverse(done)
  end

  # The drawn line a comment still belongs to: the same side, number and text,
  # and for a removed line the same view, since old-side numbers differ by view.
  defp anchor(comment, rows, filter) do
    if comparable?(comment, filter),
      do: Enum.find(rows, &(at?(&1, comment) and &1.text == comment.line_text))
  end

  # Only a line drawn there reading differently has changed; one out of view has not.
  defp changed?(comment, rows, filter) do
    comparable?(comment, filter) and Enum.any?(rows, &(at?(&1, comment) and &1.text != comment.line_text))
  end

  defp comparable?(%{line_kind: :deleted, filter: written_in}, filter), do: written_in == filter
  defp comparable?(_comment, _filter), do: true

  defp at?(%{kind: :line, line_kind: :deleted, old_line: line}, %{line_kind: :deleted, line: line}), do: true

  defp at?(%{kind: :line, line_kind: kind, new_line: line}, %{line_kind: other, line: line}),
    do: kind != :deleted and other != :deleted

  defp at?(_row, _comment), do: false
end
