defmodule Rail.Pipeline.Actions.ExpandDiffGap do
  @moduledoc false

  alias Rail.Pipeline.Schemas.Task

  @doc """
  Reads unchanged lines across a gap from git or disk and returns `{gap_key, lines}`.
  If the file lines cannot be read, returns an empty list under the gap key.
  """
  def expand_diff_gap(%Task{} = task, file_path, gap_index, start_line, end_line, diff_rev)
      when is_binary(file_path) and is_integer(gap_index) and is_integer(start_line) and is_integer(end_line) do
    gap_key = "#{file_path}:#{gap_index}"

    if Task.worktree_present?(task) do
      case Rail.Git.file_lines(task.worktree_path, file_path, rev: diff_rev) do
        lines when is_list(lines) ->
          count = max(0, end_line - start_line + 1)
          start_idx = max(0, start_line - 1)
          sliced = Enum.slice(lines, start_idx, count)
          {gap_key, sliced}

        nil ->
          {gap_key, []}
      end
    else
      {gap_key, []}
    end
  end
end
