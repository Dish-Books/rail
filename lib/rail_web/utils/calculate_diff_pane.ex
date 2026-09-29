defmodule RailWeb.Utils.CalculateDiffPane do
  @moduledoc """
  What each part of the diff pane draws, split the way LiveView patches it.

  The browser redraws everything under whatever a patch touches, so the toolbar,
  the file list and each file are live components of their own. The pane draws
  itself whole only when its frame moves; the stage owning it compares these
  parts to send any other change to the part it moved.
  """

  @doc """
  The pane's `frame`, which only changes when files come or go, then the
  assigns of its `toolbar`, its file `tree` (`nil` while there are no files) and
  each of its `sections`, keyed by the id that file's component goes by.
  """
  def calculate_diff_pane(assigns) do
    %{files: files, query: query, target: target, collapsed: collapsed, expanded_gaps: expanded_gaps} = assigns
    visible = Enum.filter(files, &matches?(&1, query))

    shared =
      for {path, count} <- Enum.frequencies_by(files, & &1.path), count > 1 or path == "", into: MapSet.new(), do: path

    %{
      frame: %{
        sections: Enum.map(visible, &section_id(&1, shared)),
        empty_message: if(files == [], do: assigns.empty_message),
        no_match: if(files != [] and visible == [], do: query),
        scroll_to: assigns.scroll_to
      },
      toolbar: %{
        target: target,
        show_file_tree: assigns.show_file_tree,
        filter: assigns.filter,
        query: query,
        additions: Enum.sum_by(files, & &1.additions),
        deletions: Enum.sum_by(files, & &1.deletions),
        viewed: Enum.count(files, & &1.viewed?),
        total: length(files)
      },
      tree:
        if(files != [],
          do: %{
            target: target,
            show?: assigns.show_file_tree,
            label: files_changed(files),
            rows: Enum.map(visible, &tree_row(&1, shared, assigns.selected_file))
          }
        ),
      sections:
        Enum.map(visible, fn file ->
          gap_keys = for %{kind: :gap, key: key} <- file.rows, do: key

          {section_id(file, shared),
           %{
             target: target,
             file: Map.drop(file, [:rows, :viewed?]),
             rows: file.rows,
             viewed?: file.viewed?,
             collapsed?: file.path in collapsed,
             expanded_gaps: Map.take(expanded_gaps, gap_keys)
           }}
        end)
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

  defp tree_row(file, shared, selected_file) do
    %{
      id: section_id(file, shared),
      file: Map.drop(file, [:rows, :viewed?]),
      viewed?: file.viewed?,
      selected?: file.path == selected_file
    }
  end
end
