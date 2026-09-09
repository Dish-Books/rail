defmodule Rail.Git.Utils.GitCmd do
  @moduledoc false

  alias Rail.ToolEnv

  @doc """
  Executes a git command with the given arguments and options.
  """
  def git_cmd(args, opts \\ []) when is_list(args) do
    ToolEnv.run("git", args, opts)
  end
end
