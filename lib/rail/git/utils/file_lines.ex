defmodule Rail.Git.Utils.FileLines do
  @moduledoc false

  alias Rail.Tools

  @doc """
  The lines of `path` as it is in `worktree_path`, or as it was at `revision`, or
  `nil` when there is no file there to read.

  Lines are split the way a diff numbers them, so line `n` here is line `n` there.
  """
  def file_lines(worktree_path, path, revision \\ :worktree)

  # A path that climbs out of the worktree, or follows a link an agent could point
  # anywhere, names nothing in it, whoever sent it.
  def file_lines(worktree_path, path, :worktree) do
    root = Path.expand(worktree_path)
    full_path = root |> Path.join(path) |> Path.expand()

    with true <- String.starts_with?(full_path, root <> "/"),
         false <- linked?(root, full_path),
         false <- File.dir?(full_path),
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

  defp linked?(root, full_path) do
    full_path
    |> Path.relative_to(root)
    |> Path.split()
    |> Enum.scan(root, &Path.join(&2, &1))
    |> Enum.any?(&match?({:ok, %File.Stat{type: :symlink}}, File.lstat(&1)))
  end

  defp lines(content) do
    case String.split(content, ~r/\r?\n/) do
      [""] -> []
      list -> if List.last(list) == "", do: Enum.slice(list, 0..-2//1), else: list
    end
  end
end
