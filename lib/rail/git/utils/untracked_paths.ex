defmodule Rail.Git.Utils.UntrackedPaths do
  @moduledoc false

  alias Rail.Tools

  @doc """
  The files in `worktree_path` git has never seen and is not told to ignore.
  """
  def untracked_paths(worktree_path) do
    case Tools.run("git", ["ls-files", "--others", "--exclude-standard"],
           cd: worktree_path,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        output
        |> String.split(~r/\r?\n/)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      _unreadable ->
        []
    end
  end
end
