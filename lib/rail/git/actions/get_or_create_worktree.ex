defmodule Rail.Git.Actions.GetOrCreateWorktree do
  @moduledoc false

  import Rail.Git.Utils.WithCloneLock
  import Rail.Git.Utils.WriteEnvBlock

  alias Rail.Git
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Tools

  @doc """
  Gets the task's existing checkout or makes it: a clone of the project's clone, hardlinked where the disk allows,
  with the clone's `origin` and no hooks, since Rail runs none of a project's. A task with a pull request continues its branch as `origin` has it; any other
  starts a new one from `origin/<default branch>`, fetched first.
  """
  def get_or_create_worktree(%Project{} = project, %Task{} = task) do
    branch = task.worktree_name || task.id
    worktree_path = task.worktree_path || Path.join(project.clone_path, ".worktrees/#{branch}")

    if File.dir?(worktree_path),
      do: {:ok, worktree_path},
      # Two starts at once build in one place, so the second waits and then finds the first's clone.
      else: with_clone_lock(worktree_path, fn -> make(project, task, worktree_path, branch) end)
  end

  defp make(%Project{} = project, %Task{} = task, worktree_path, branch) do
    if File.dir?(worktree_path) do
      {:ok, worktree_path}
    else
      # Made beside its path and moved in last, so a failure or a restart midway leaves nothing to reuse.
      building = worktree_path <> ".new"
      File.rm_rf!(building)
      File.mkdir_p!(Path.dirname(worktree_path))

      # Fetched first, since a clone takes its default branch from the project clone's local one, which the fetch moves.
      with :ok <- Git.fetch_default_branch(project, project.clone_path),
           :ok <- clone(project, building),
           :ok <- Git.copy_default_branch(project, building),
           :ok <- check_out(project, task, building, branch),
           :ok <- with_clone_lock(project.clone_path, fn -> move_in(project, building, worktree_path) end) do
        {:ok, worktree_path}
      else
        {:error, reason} ->
          File.rm_rf!(building)
          {:error, failed(worktree_path, reason)}
      end
    end
  end

  # A plain path rather than --local, which fails outright where git cannot hardlink.
  defp clone(%Project{clone_path: clone_path, default_branch: default}, building) do
    args = ["clone", "--quiet", "--no-checkout", "--single-branch", "--branch", default, clone_path, building]

    with {origin, 0} <- git(clone_path, ["remote", "get-url", "origin"]),
         {_cloned, 0} <- with_clone_lock(clone_path, fn -> git(clone_path, args) end),
         {_set, 0} <- git(building, ["remote", "set-url", "origin", String.trim(origin)]),
         # A push updates origin/<branch> only through a fetch refspec that names it, which --single-branch narrows.
         {_widened, 0} <- git(building, ["config", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*"]) do
      :ok
    else
      {output, _code} -> {:error, String.trim(output)}
    end
  end

  defp check_out(%Project{} = project, %Task{pr_number: number}, building, branch) when is_integer(number) do
    with :ok <- Git.fetch_branch(project, building, branch), do: checkout(building, [branch])
  end

  # No upstream, so the branch reads as never pushed rather than as tracking the base.
  defp check_out(%Project{} = project, %Task{}, building, branch) do
    checkout(building, ["--no-track", "-b", branch, "origin/#{project.default_branch}"])
  end

  defp checkout(building, args) do
    case git(building, ["checkout", "--quiet" | args]) do
      {_output, 0} -> :ok
      {output, _code} -> {:error, String.trim(output)}
    end
  end

  # With no script to wait on it gets the .env as it is made; otherwise the setup run copies it.
  # Under the clone's lock, as save_env_file/2 writes every task's .env under it.
  defp move_in(%Project{} = project, building, worktree_path) do
    env = if project.worktree_setup_script in [nil, ""], do: write_env_block(project, building), else: :ok

    with :ok <- env do
      case File.rename(building, worktree_path) do
        :ok -> :ok
        {:error, reason} -> {:error, "#{worktree_path}: #{:file.format_error(reason)}"}
      end
    end
  end

  defp failed(worktree_path, reason) when is_binary(reason),
    do: "Failed to create the task's clone at #{worktree_path}: #{reason}"

  defp failed(_worktree_path, reason), do: reason

  defp git(path, args), do: Tools.run("git", args, cd: path, stderr_to_stdout: true)
end
