defmodule Rail.Git.Actions.RemoveWorktree do
  @moduledoc false

  alias Rail.ToolEnv

  @doc """
  Removes a git worktree and prunes worktree metadata.
  """
  def remove_worktree(repo_path, worktree_path, opts \\ []) when is_binary(repo_path) and is_binary(worktree_path) do
    force? = Keyword.get(opts, :force, true)

    result =
      if File.dir?(worktree_path) do
        args =
          if force? do
            ["worktree", "remove", "--force", worktree_path]
          else
            ["worktree", "remove", worktree_path]
          end

        ToolEnv.run("git", args, cd: repo_path, stderr_to_stdout: true)
      else
        {"", 0}
      end

    ToolEnv.run("git", ["worktree", "prune"], cd: repo_path, stderr_to_stdout: true)

    case result do
      {_out, 0} ->
        :ok

      {output, _code} ->
        if File.dir?(worktree_path) do
          {:error, String.trim(output)}
        else
          :ok
        end
    end
  end
end
