defmodule Rail.Git.Actions.FileLines do
  @moduledoc false

  alias Rail.ToolEnv

  @doc """
  Returns the lines of a file in the worktree, either from a git revision
  or directly from the working disk copy. Returns nil on failure.
  """
  def file_lines(worktree_path, relative_path, opts \\ []) when is_binary(worktree_path) and is_binary(relative_path) do
    rev = Keyword.get(opts, :rev)

    if is_binary(rev) and rev != "" do
      case ToolEnv.run("git", ["show", "#{rev}:#{relative_path}"],
             cd: worktree_path,
             stderr_to_stdout: true
           ) do
        {output, 0} ->
          split_lines(output)

        _error ->
          nil
      end
    else
      full_path = Path.join(worktree_path, relative_path)

      if File.dir?(full_path) do
        nil
      else
        case File.read(full_path) do
          {:ok, content} ->
            split_lines(content)

          _error ->
            nil
        end
      end
    end
  end

  defp split_lines(content) do
    case String.split(content, ~r/\r?\n/) do
      [""] ->
        []

      list ->
        if List.last(list) == "" do
          Enum.slice(list, 0..-2//1)
        else
          list
        end
    end
  end
end
