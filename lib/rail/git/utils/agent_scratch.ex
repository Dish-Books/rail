defmodule Rail.Git.Utils.AgentScratch do
  @moduledoc false

  @doc """
  True for a worktree path under `.rail/scratch/`, the agents' own scratch, which is
  never part of the change. The rest of `.rail/`, such as the project's prompts, is.
  """
  def agent_scratch?(path) when is_binary(path) do
    path == ".rail/scratch" or String.starts_with?(path, ".rail/scratch/")
  end
end
