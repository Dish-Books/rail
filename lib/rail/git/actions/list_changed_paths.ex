defmodule Rail.Git.Actions.ListChangedPaths do
  @moduledoc false

  import Rail.Git.Utils.UntrackedPaths

  alias Rail.Tools

  @doc """
  Every path in `worktree_path` that differs from `HEAD`, changed, deleted or untracked, sorted.
  """
  def list_changed_paths(worktree_path) when is_binary(worktree_path) do
    tracked =
      case Tools.run("git", ["diff", "--name-only", "-z", "HEAD"], cd: worktree_path, stderr_to_stdout: true) do
        {output, 0} -> String.split(output, <<0>>, trim: true)
        _unreadable -> []
      end

    Enum.sort(Enum.uniq(tracked ++ untracked_paths(worktree_path)))
  end
end
