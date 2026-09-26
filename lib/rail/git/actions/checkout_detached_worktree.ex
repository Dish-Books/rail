defmodule Rail.Git.Actions.CheckoutDetachedWorktree do
  @moduledoc false

  alias Rail.Git
  alias Rail.Projects.Schemas.Project
  alias Rail.Tools

  @doc """
  Checks out `origin/<default branch>` at `worktree_path` with no branch, for a
  pass that reads the code as it stands and writes nothing back. Whatever an
  earlier pass left at the path is removed first.
  """
  def checkout_detached_worktree(%Project{clone_path: repo_path} = project, worktree_path)
      when is_binary(worktree_path) do
    with :ok <- Git.fetch_default_branch(project, repo_path),
         :ok <- Git.remove_worktree(repo_path, worktree_path) do
      File.mkdir_p!(Path.dirname(worktree_path))
      args = ["worktree", "add", "--detach", worktree_path, "origin/#{project.default_branch}"]

      case Tools.run("git", args, cd: repo_path, stderr_to_stdout: true) do
        {_out, 0} ->
          {:ok, worktree_path}

        {out, code} ->
          {:error,
           "Failed to create worktree at #{worktree_path} " <>
             "(git #{Enum.join(args, " ")} exited #{code}): #{String.trim(out)}"}
      end
    end
  end
end
