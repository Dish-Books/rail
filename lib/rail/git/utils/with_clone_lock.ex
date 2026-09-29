defmodule Rail.Git.Utils.WithCloneLock do
  @moduledoc false

  @doc """
  Runs `fun` while no other git step on the clone at `repo_path` runs.

  Worktrees share their clone's refs, and a fetch there while another worktree
  is being added or removed fails on the half-made one, so fetches and worktree
  changes on one clone take turns.
  """
  def with_clone_lock(repo_path, fun) when is_binary(repo_path) and is_function(fun, 0) do
    :global.trans({{__MODULE__, Path.expand(repo_path)}, self()}, fun, [node()], :infinity)
  end
end
