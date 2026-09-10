defmodule Rail.Git.Actions.HeadSha do
  @moduledoc false

  import Rail.Git.Utils.GitCmd

  @doc """
  Returns the short HEAD commit SHA of the worktree, or nil on failure.
  """
  def head_sha(worktree_path) when is_binary(worktree_path) do
    case git_cmd(["rev-parse", "--short", "HEAD"], cd: worktree_path, stderr_to_stdout: true) do
      {output, 0} ->
        sha = String.trim(output)
        if sha == "", do: nil, else: sha

      _other ->
        nil
    end
  end
end
