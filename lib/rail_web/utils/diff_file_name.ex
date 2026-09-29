defmodule RailWeb.Utils.DiffFileName do
  @moduledoc """
  How a file in a diff is named: the directory it sits in and the part that
  says which file it is, so a file's header and its row in the file list agree.
  """

  @doc """
  The `dir` (with its trailing slash, or `nil` at the root) and `name` a diff
  file is shown by. A rename is the whole point of its name, so it stays one piece.
  """
  def diff_file_name(%{display_path: display_path}) do
    cond do
      String.contains?(display_path, " → ") -> %{dir: nil, name: display_path}
      Path.dirname(display_path) == "." -> %{dir: nil, name: display_path}
      true -> %{dir: Path.dirname(display_path) <> "/", name: Path.basename(display_path)}
    end
  end
end
