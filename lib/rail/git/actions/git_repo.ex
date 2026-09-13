defmodule Rail.Git.Actions.GitRepo do
  @moduledoc false

  @doc """
  Returns true if `path` is the root of a git checkout: a directory holding
  `.git`, which is a file when the checkout is itself a worktree.
  """
  def git_repo?(path) when is_binary(path) do
    File.exists?(Path.join(path, ".git"))
  end
end
