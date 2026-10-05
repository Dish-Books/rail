defmodule Rail.Git.Actions.ExpandDiffGap do
  @moduledoc """
  Fills in the unchanged lines a diff left out between two hunks.

  The lines are read off disk rather than out of a revision, because the diff
  being read runs to the working tree: what sits in the gap is what is there now.
  """

  import Rail.Git.Utils.FileLines
  import Rail.Git.Utils.HighlightLines

  alias Rail.Pipeline.Schemas.Task

  @doc """
  Returns `{gap_key, lines}` for the gap `gap_index` of `path`, empty when the
  file cannot be read.

  Each line is a `%{text:, html:}`, the same shape the rows around it carry, so
  the pane draws an opened gap exactly as it draws the hunk it sits between.
  """
  def expand_diff_gap(%Task{} = task, path, gap_index, start_line, end_line)
      when is_binary(path) and is_integer(gap_index) and is_integer(start_line) and is_integer(end_line) do
    key = "#{path}:#{gap_index}"

    case Task.worktree_present?(task) && file_lines(task.worktree_path, path) do
      lines when is_list(lines) -> {key, gap(lines, path, start_line, end_line)}
      _unreadable -> {key, []}
    end
  end

  # The whole file is highlighted, so a gap inside a comment or heredoc that opens
  # above it reads the way the file does. A file that is not text cannot be, so the gap alone is.
  defp gap(lines, path, start_line, end_line) do
    first = max(0, start_line - 1)
    count = max(0, end_line - start_line + 1)
    gap = Enum.slice(lines, first, count)

    html =
      if Enum.all?(lines, &String.valid?/1),
        do: lines |> highlight_lines(path) |> Enum.slice(first, count),
        else: highlight_lines(gap, path)

    Enum.zip_with(html, gap, fn html, text -> %{text: text, html: html} end)
  end
end
