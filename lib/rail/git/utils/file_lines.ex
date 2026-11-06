defmodule Rail.Git.Utils.FileLines do
  @moduledoc false

  import Rail.Git.Utils.FileContent

  @doc """
  The lines of `path` as it is in `worktree_path`, or as it was at `revision`, or
  `nil` when there is no file there to read.

  Lines are split the way a diff numbers them, so line `n` here is line `n` there.
  """
  def file_lines(worktree_path, path, revision \\ :worktree) do
    case file_content(worktree_path, path, revision) do
      content when is_binary(content) -> lines(content)
      nil -> nil
    end
  end

  defp lines(content) do
    case String.split(content, ~r/\r?\n/) do
      [""] -> []
      list -> if List.last(list) == "", do: Enum.slice(list, 0..-2//1), else: list
    end
  end
end
