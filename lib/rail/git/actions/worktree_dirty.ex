defmodule Rail.Git.Actions.WorktreeDirty do
  @moduledoc false

  import Rail.Git.Utils.AgentScratch

  alias Rail.Tools

  @doc """
  True when the worktree has changes nobody has committed.

  `.rail/scratch/` is left out, exactly as `branch_fingerprint/1` leaves it out: agents
  write their own scratch there and it is never part of the deliverable, so a
  tree holding nothing else is clean.
  """
  def worktree_dirty?(worktree_path) when is_binary(worktree_path) do
    case Tools.run("git", ["status", "--porcelain", "--untracked-files=all"],
           cd: worktree_path,
           stderr_to_stdout: true
         ) do
      {output, 0} -> Enum.any?(String.split(output, ~r/\r?\n/), &counts?/1)
      _unreadable -> false
    end
  end

  defp counts?(line) do
    case String.trim(line) do
      "" ->
        false

      _trimmed ->
        path = line |> String.slice(3..-1//1) |> String.trim() |> String.replace("\"", "")
        not agent_scratch?(path)
    end
  end
end
