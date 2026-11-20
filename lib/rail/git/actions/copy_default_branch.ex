defmodule Rail.Git.Actions.CopyDefaultBranch do
  @moduledoc false

  alias Rail.Projects.Schemas.Project
  alias Rail.Tools

  @doc """
  Brings the repository at `repo_path` up to the default branch the project's clone last fetched, when it is a clone
  of its own; a worktree already shares the clone's. Returns `:ok` or `{:error, output}`.
  """
  def copy_default_branch(%Project{clone_path: clone_path, default_branch: branch}, repo_path)
      when is_binary(repo_path) do
    if File.dir?(Path.join(repo_path, ".git")) and Path.expand(repo_path) != Path.expand(clone_path) do
      ref = "refs/remotes/origin/#{branch}"

      case git(repo_path, ["fetch", "--quiet", clone_path, "+#{ref}:#{ref}"]) do
        {_output, 0} ->
          # Refused only while the branch is checked out there, when it is the agent's to move.
          _moved = git(repo_path, ["branch", "--force", branch, "origin/#{branch}"])
          :ok

        {output, _code} ->
          {:error, String.trim(output)}
      end
    else
      :ok
    end
  end

  defp git(path, args), do: Tools.run("git", args, cd: path, stderr_to_stdout: true)
end
