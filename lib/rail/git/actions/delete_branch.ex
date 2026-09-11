defmodule Rail.Git.Actions.DeleteBranch do
  @moduledoc false

  alias Rail.ToolEnv

  @doc """
  Deletes a local branch.
  """
  def delete_branch(repo_path, branch, opts \\ []) when is_binary(repo_path) and is_binary(branch) do
    force? = Keyword.get(opts, :force, true)
    flag = if force?, do: "-D", else: "-d"

    case ToolEnv.run("git", ["branch", flag, branch], cd: repo_path, stderr_to_stdout: true) do
      {_out, 0} ->
        :ok

      {output, _code} ->
        {:error, String.trim(output)}
    end
  end
end
