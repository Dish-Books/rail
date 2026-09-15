defmodule Rail.Git.Actions.ExpandDiffGap do
  @moduledoc """
  Fills in the unchanged lines a diff left out between two hunks.

  The lines are read off disk rather than out of a revision, because the diff
  being read runs to the working tree: what sits in the gap is what is there now.
  """

  alias Rail.Pipeline.Schemas.Task

  @doc """
  Returns `{gap_key, lines}` for the gap `gap_index` of `path`, empty when the
  file cannot be read.
  """
  def expand_diff_gap(%Task{} = task, path, gap_index, start_line, end_line)
      when is_binary(path) and is_integer(gap_index) and is_integer(start_line) and is_integer(end_line) do
    key = "#{path}:#{gap_index}"

    case Task.worktree_present?(task) && file_lines(task.worktree_path, path) do
      lines when is_list(lines) -> {key, Enum.slice(lines, max(0, start_line - 1), max(0, end_line - start_line + 1))}
      _unreadable -> {key, []}
    end
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
