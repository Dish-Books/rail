defmodule Rail.Git.Actions.ListUntrackedFiles do
  @moduledoc false

  alias Rail.Tools

  @doc """
  Lists untracked files in the worktree that are not ignored.
  """
  def list_untracked_files(worktree_path) when is_binary(worktree_path) do
    case Tools.run("git", ["ls-files", "--others", "--exclude-standard"],
           cd: worktree_path,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        output
        |> String.split(~r/\r?\n/)
        |> Enum.map(&String.trim/1)
        |> Enum.filter(&(&1 != ""))

      _other ->
        []
    end
  end
end
