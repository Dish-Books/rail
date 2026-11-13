defmodule RailWeb.Utils.CalculateDiffPane do
  @moduledoc """
  What each part of the diff pane draws, split the way LiveView patches it.

  The browser redraws everything under whatever a patch touches, so the toolbar,
  the file list and each file are live components of their own. `RailWeb.Live.DiffView`
  draws the pane again only when its `frame` changes, and otherwise sends each part
  that moved its own update, so a change reaches only that part.
  """

  use RailWeb, :verified_routes

  import RailWeb.Utils.TestFile

  @doc """
  The pane's `frame`, which only changes when files come or go or a comment's
  file leaves the view (`stray`), then the assigns of its `toolbar`, its file
  `tree` (`nil` while there are no files) and each of its `sections`, keyed by
  the id that file's component goes by. A section's rows come in `segments`, cut
  after each line with comments or the comment being written under it, and the
  comments that no longer have their line are `lifted` to the top of it. Only
  unsent comments are counted, since the counts are of what Send would send.
  `hide_tests` leaves test files out as the query does, and `no_match` says why nothing is left.
  `filter` is the view: `:branch`, `:uncommitted` or `{:commit, sha}`. A picture's
  section carries the `image` addresses of its `old` and `new` sides, each `nil`
  where the file has no such side; any other file's is `nil`.
  """
  def calculate_diff_pane(assigns) do
    %{files: files, query: query, hide_tests: hide_tests} = assigns
    {matched, visible} = visible(files, query, hide_tests)
    comments = Enum.group_by(assigns.comments, & &1.path)
    open = MapSet.new(assigns.open_comments)

    shared =
      for {path, count} <- Enum.frequencies_by(files, & &1.path), count > 1 or path == "", into: MapSet.new(), do: path

    %{
      frame: %{
        sections: Enum.map(visible, &section_id(&1, shared)),
        empty_message: if(files == [], do: assigns.empty_message),
        no_match: if(files != [] and visible == [], do: no_match(query, matched)),
        scroll_to: assigns.scroll_to,
        stray: stray(comments, files, open)
      },
      toolbar: toolbar(assigns),
      tree: if(files != [], do: tree(visible, shared, comments, assigns)),
      sections: Enum.map(visible, &{section_id(&1, shared), section(&1, Map.get(comments, &1.path, []), open, assigns)})
    }
  end

  defp toolbar(%{files: files} = assigns) do
    %{
      target: assigns.target,
      show_file_tree: assigns.show_file_tree,
      picker: assigns.picker,
      wrap: assigns.wrap,
      query: assigns.query,
      hide_tests: assigns.hide_tests,
      test_count: Enum.count(files, &test_file?(&1.path)),
      additions: Enum.sum_by(files, & &1.additions),
      deletions: Enum.sum_by(files, & &1.deletions),
      viewed: Enum.count(files, & &1.viewed?),
      total: length(files),
      unsent: Enum.count(assigns.comments, &(&1.status == :unsent)),
      commentable?: assigns.commentable?
    }
  end

  defp tree(visible, shared, comments, assigns) do
    %{
      target: assigns.target,
      show?: assigns.show_file_tree,
      label: files_changed(assigns.files),
      rows: Enum.map(visible, &tree_row(&1, shared, assigns.selected_file, comments)),
      list: assigns.comment_list,
      file_count: length(assigns.files),
      comment_count: length(assigns.comments),
      selected_comment: assigns.selected_comment,
      groups: comment_groups(assigns.comments, comments, assigns.files, assigns.filter, assigns.reader_id)
    }
  end

  defp visible(files, query, hide_tests) do
    matched = Enum.filter(files, &matches?(&1, query))
    {matched, if(hide_tests, do: Enum.reject(matched, &test_file?(&1.path)), else: matched)}
  end

  defp matches?(_file, ""), do: true
  defp matches?(file, query), do: String.contains?(String.downcase(file.path), String.downcase(query))

  # Only reached with nothing left to show, so anything the query matched is a hidden test.
  defp no_match("", _matched), do: "Every file here is a test, and tests are hidden."
  defp no_match(query, []), do: "No file here matches #{query}."
  defp no_match(query, _tests), do: "Only tests match #{query}, and tests are hidden."

  defp files_changed([_one]), do: "1 file changed"
  defp files_changed(files), do: "#{length(files)} files changed"

  # A path keeps naming a file while its contents change, so its part is patched
  # rather than replaced. A path that is not one file's alone takes the digest:
  # a file that changed type is two blocks, and one that would not parse has none.
  defp section_id(%{path: path, digest: digest}, shared) do
    if MapSet.member?(shared, path), do: digest, else: path
  end

  # Only a file missing from the view entirely: one the query hides is still there.
  defp stray(comments, files, open) do
    paths = MapSet.new(files, & &1.path)

    for {path, mine} <- Enum.sort(comments),
        not MapSet.member?(paths, path),
        do: {path, Enum.map(mine, &{&1, MapSet.member?(open, &1.id)})}
  end

  # Empty groups are left out; each keeps the order the comments were listed in.
  defp comment_groups(comments, by_path, files, filter, reader_id) do
    changed =
      for file <- files,
          comment <- Map.get(by_path, file.path, []),
          changed?(comment, file.rows, filter),
          into: MapSet.new(),
          do: comment.id

    by_status = Enum.group_by(comments, & &1.status)

    for {status, label} <- [unsent: "Not sent", sent: "Sent", resolved: "Resolved"],
        Map.has_key?(by_status, status),
        do: %{
          status: status,
          label: label,
          rows:
            Enum.map(
              by_status[status],
              &%{comment: &1, changed?: MapSet.member?(changed, &1.id), mine?: &1.user_id == reader_id}
            )
        }
  end

  defp tree_row(file, shared, selected_file, comments) do
    %{
      id: section_id(file, shared),
      file: Map.drop(file, [:rows, :viewed?]),
      viewed?: file.viewed?,
      selected?: file.path == selected_file,
      unsent: unsent(Map.get(comments, file.path, []))
    }
  end

  defp section(file, comments, open, assigns) do
    gap_keys = for %{kind: :gap, key: key} <- file.rows, do: key
    draft = if assigns.draft && assigns.draft.path == file.path, do: assigns.draft
    {placed, lifted} = Enum.split_with(comments, &(anchor(&1, file.rows, assigns.filter) != nil))
    lifted = Enum.map(lifted, &{&1, changed?(&1, file.rows, assigns.filter)})

    %{
      target: assigns.target,
      file: Map.drop(file, [:rows, :viewed?]),
      segments: segments(file.rows, placed, draft, assigns.filter),
      lifted: lifted,
      changed_count: Enum.count(lifted, fn {comment, changed?} -> changed? and comment.status == :unsent end),
      unsent: unsent(comments),
      open: for(comment <- comments, MapSet.member?(open, comment.id), do: comment.id),
      reader_id: assigns.reader_id,
      commentable?: assigns.commentable?,
      viewed?: file.viewed?,
      collapsed?: file.path in assigns.collapsed,
      expanded_gaps: Map.take(assigns.expanded_gaps, gap_keys),
      image: image(file, assigns)
    }
  end

  # The digest rides along so a picture that changed is fetched again rather than
  # kept from the last time it was drawn.
  defp image(%{image?: true} = file, assigns) do
    %{
      old: if(file.status != :added, do: image_src(assigns, :old, file.old_path || file.path, file.digest)),
      new: if(file.status != :deleted, do: image_src(assigns, :new, file.path, file.digest))
    }
  end

  defp image(_file, _assigns), do: nil

  defp image_src(assigns, side, path, digest) do
    query = Enum.reject([path: path, view: view_param(assigns.filter), v: digest], &is_nil(elem(&1, 1)))

    ~p"/tasks/#{assigns.task_id}/diff/#{side}?#{query}"
  end

  defp view_param(:branch), do: nil
  defp view_param(:uncommitted), do: "uncommitted"
  defp view_param({:commit, sha}), do: sha

  defp unsent(comments), do: Enum.count(comments, &(&1.status == :unsent))

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

  # The drawn line a comment still belongs to: the same side, number and text, for
  # a removed line the same view, since old-side numbers differ by view, and for a
  # commit's line only that commit's view, since its numbers are that commit's.
  defp anchor(comment, rows, filter) do
    if comparable?(comment, filter),
      do: Enum.find(rows, &(at?(&1, comment) and &1.text == comment.line_text))
  end

  # Only a line drawn there reading differently has changed; one out of view has not.
  defp changed?(comment, rows, filter) do
    comparable?(comment, filter) and Enum.any?(rows, &(at?(&1, comment) and &1.text != comment.line_text))
  end

  defp comparable?(%{filter: :commit, commit: commit}, filter), do: filter == {:commit, commit}
  defp comparable?(_comment, {:commit, _sha}), do: false
  defp comparable?(%{line_kind: :deleted, filter: written_in}, filter), do: written_in == filter
  defp comparable?(_comment, _filter), do: true

  defp at?(%{kind: :line, line_kind: :deleted, old_line: line}, %{line_kind: :deleted, line: line}), do: true

  defp at?(%{kind: :line, line_kind: kind, new_line: line}, %{line_kind: other, line: line}),
    do: kind != :deleted and other != :deleted

  defp at?(_row, _comment), do: false
end
