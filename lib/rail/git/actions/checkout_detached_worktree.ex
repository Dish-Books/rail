defmodule Rail.Git.Actions.CheckoutDetachedWorktree do
  @moduledoc false

  import Rail.Git.Utils.WithCloneLock

  alias Rail.Git
  alias Rail.Projects.Schemas.Project
  alias Rail.Tools

  @doc """
  Checks out `origin/<default branch>` at `worktree_path` with no branch, in a clone of the project's clone, for a pass
  that reads the code as it stands and writes nothing back. Whatever an earlier pass left at the path is removed first.
  """
  def checkout_detached_worktree(%Project{clone_path: repo_path, default_branch: branch} = project, worktree_path)
      when is_binary(worktree_path) do
    with :ok <- Git.fetch_default_branch(project, repo_path),
         :ok <- Git.remove_worktree(repo_path, worktree_path) do
      File.mkdir_p!(Path.dirname(worktree_path))
      args = ["clone", "--quiet", "--no-checkout", "--single-branch", "--branch", branch, repo_path, worktree_path]

      # A clone takes the clone's local default branch, so origin's is copied in before the checkout.
      with :ok <- with_clone_lock(repo_path, fn -> git(repo_path, args) end),
           :ok <- Git.copy_default_branch(project, worktree_path),
           :ok <- git(worktree_path, ["checkout", "--quiet", "--detach", "origin/#{branch}"]) do
        {:ok, worktree_path}
      else
        {:error, output} ->
          File.rm_rf!(worktree_path)
          {:error, "Failed to create the checkout at #{worktree_path}: #{output}"}
      end
    end
  end

  defp git(path, args) do
    case Tools.run("git", args, cd: path, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, _code} -> {:error, String.trim(output)}
    end
  end
end
