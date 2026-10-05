defmodule Rail.Git.Utils.FileLines do
  @moduledoc false

  alias Rail.Tools

  @doc """
  The lines of `path` as it is in `worktree_path`, or as it was at `revision`, or
  `nil` when there is no file there to read.

  Lines are split the way a diff numbers them, so line `n` here is line `n` there.
  """
  def file_lines(worktree_path, path, revision \\ :worktree)

  def file_lines(worktree_path, path, :worktree) do
    full_path = Path.join(worktree_path, path)

    with false <- File.dir?(full_path),
         {:ok, content} <- File.read(full_path) do
      lines(content)
    else
      _unreadable -> nil
    end
  end

  # `cat-file blob` rather than `show`, which lists a directory instead of failing.
  def file_lines(worktree_path, path, revision) when is_binary(revision) do
    case Tools.run("git", ["cat-file", "blob", "#{revision}:#{path}"], cd: worktree_path, stderr_to_stdout: true) do
      {content, 0} -> lines(content)
      _absent -> nil
    end
  end

  defp lines(content) do
    case String.split(content, ~r/\r?\n/) do
      [""] -> []
      list -> if List.last(list) == "", do: Enum.slice(list, 0..-2//1), else: list
    end
  end
end
