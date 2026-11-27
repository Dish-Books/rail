defmodule Rail.Git.Utils.FileLines do
  @moduledoc false

  import Rail.Git.Utils.FileContent

  @doc """
  The lines of `path` as it was at `revision` in the repository at `repo_path`, or `nil` when there is no file there
  to read.

  Lines are split the way a diff numbers them, so line `n` here is line `n` there.
  """
  def file_lines(repo_path, path, revision) do
    case file_content(repo_path, path, revision) do
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
