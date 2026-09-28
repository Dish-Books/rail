defmodule Rail.Git.Utils.UntrackedPaths do
  @moduledoc false

  alias Rail.Tools

  @doc """
  The files in `worktree_path` git has never seen and is not told to ignore.

  The agents' own scratch under `.rail/` is left out, because it is never part
  of the change.
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
        |> Enum.reject(&(&1 == "" or String.starts_with?(&1, ".rail/")))

      _unreadable ->
        []
    end
  end
end
