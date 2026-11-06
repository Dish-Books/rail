defmodule Rail.Git.Actions.GetOrCreateWorktree do
  @moduledoc false

  import Rail.Git.Utils.WithCloneLock
  import Rail.Git.Utils.WriteEnvBlock

  alias Rail.Git
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Tools

  @doc """
  Gets the task's existing worktree directory or creates a new one.

  The repo, the worktree path, the branch and the base branch all come from the
  project and the task. An existing branch is checked out as-is; otherwise the
  branch is created from `origin/<default branch>`, fetched first, since nothing
  else moves the clone's own copy of it.
  """
  def get_or_create_worktree(%Project{} = project, %Task{} = task) do
    repo_path = project.clone_path
    branch = task.worktree_name || task.id
    worktree_path = task.worktree_path || Path.join(repo_path, ".worktrees/#{branch}")

    if File.dir?(worktree_path) do
      {:ok, worktree_path}
    else
      File.mkdir_p!(Path.dirname(worktree_path))

      case create_worktree(project, worktree_path, branch) do
        :ok -> {:ok, worktree_path}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp create_worktree(%Project{clone_path: repo_path} = project, worktree_path, branch) do
    if branch_exists?(repo_path, branch) do
      add_worktree(project, worktree_path, [worktree_path, branch])
    else
      # No upstream, so the branch reads as never pushed rather than as tracking the base.
      with :ok <- Git.fetch_default_branch(project, repo_path) do
        base = "origin/#{project.default_branch}"
        add_worktree(project, worktree_path, ["--no-track", "-b", branch, worktree_path, base])
      end
    end
  end

  defp add_worktree(%Project{clone_path: repo_path} = project, worktree_path, add_args) do
    args = ["worktree", "add" | add_args]

    with_clone_lock(repo_path, fn ->
      case Tools.run("git", args, cd: repo_path, stderr_to_stdout: true) do
        # With no script to wait on it is set up as it is made; otherwise the setup run copies the .env.
        {_out, 0} when project.worktree_setup_script in [nil, ""] ->
          with {:error, message} <- write_env_block(project, worktree_path),
               do: remove_new_worktree(repo_path, worktree_path, message)

        {_out, 0} ->
          :ok

        {out, code} ->
          {:error,
           "Failed to create worktree at #{worktree_path} " <>
             "(git #{Enum.join(args, " ")} exited #{code}): #{String.trim(out)}"}
      end
    end)
  end

  # Removed, so the next attempt makes it again rather than finding a worktree with no .env.
  defp remove_new_worktree(repo_path, worktree_path, message) do
    case Tools.run("git", ["worktree", "remove", "--force", worktree_path], cd: repo_path, stderr_to_stdout: true) do
      {_out, 0} ->
        {:error, "Rail could not write the new worktree's .env (#{message}), so it removed the worktree."}

      {out, _code} ->
        {:error,
         "Rail could not write the new worktree's .env (#{message}), and could not remove #{worktree_path} " <>
           "(#{String.trim(out)}): remove it before retrying."}
    end
  end

  defp branch_exists?(repo_path, branch) do
    match?(
      {_out, 0},
      Tools.run("git", ["rev-parse", "--verify", "--quiet", "refs/heads/" <> branch],
        cd: repo_path,
        stderr_to_stdout: true
      )
    )
  end
end
