defmodule Rail.Git.Actions.ExpandDiffGap do
  @moduledoc """
  Fills in the unchanged lines a diff left out between two hunks.

  The lines are read off disk rather than out of a revision, because the diff
  being read runs to the working tree: what sits in the gap is what is there now.
  """

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

  defp gap(lines, path, start_line, end_line) do
    lines = Enum.slice(lines, max(0, start_line - 1), max(0, end_line - start_line + 1))

    lines
    |> highlight_lines(path)
    |> Enum.zip_with(lines, fn html, text -> %{text: text, html: html} end)
  end

  defp file_lines(worktree_path, path) do
    full_path = Path.join(worktree_path, path)

    if File.dir?(full_path) do
      nil
    else
      case File.read(full_path) do
        {:ok, content} -> lines(content)
        {:error, _unreadable} -> nil
      end
    end
  end

  defp lines(content) do
    case String.split(content, ~r/\r?\n/) do
      [""] -> []
      list -> if List.last(list) == "", do: Enum.slice(list, 0..-2//1), else: list
    end
  end
end
