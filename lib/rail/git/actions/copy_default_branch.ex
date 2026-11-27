defmodule Rail.Git.Actions.CopyDefaultBranch do
  @moduledoc false

  import Rail.Git.Utils.LocalCheckout

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Tools

  @doc """
  Brings a repository up to the default branch the project's clone last fetched: a task's repository, and its
  checkout when that is on Rail's disk, for a `%Task{}`, or the clone of the clone at a path. A checkout's own branch
  of that name follows it, as the clone's does. Returns `:ok` or `{:error, output}`.
  """
  def copy_default_branch(%Project{} = project, %Task{} = task) do
    with :ok <- copy(project, Task.repo_path(task), false) do
      case local_checkout(task) do
        checkout when is_binary(checkout) -> copy(project, checkout, true)
        nil -> :ok
      end
    end
  end

  def copy_default_branch(%Project{clone_path: clone_path} = project, repo_path) when is_binary(repo_path) do
    if Path.expand(repo_path) == Path.expand(clone_path), do: :ok, else: copy(project, repo_path, true)
  end

  defp copy(%Project{clone_path: clone_path, default_branch: branch}, repo_path, follow?) do
    ref = "refs/remotes/origin/#{branch}"

    case git(repo_path, ["fetch", "--quiet", "--no-write-fetch-head", clone_path, "+#{ref}:#{ref}"]) do
      {_output, 0} ->
        # Refused only while the branch is checked out there, when it is the agent's to move.
        if follow?, do: git(repo_path, ["branch", "--force", branch, "origin/#{branch}"])
        :ok

      {output, _code} ->
        {:error, String.trim(output)}
    end
  end

  defp git(path, args), do: Tools.run("git", args, cd: path, stderr_to_stdout: true)
end
