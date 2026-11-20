defmodule Rail.Git.Actions.FetchDefaultBranch do
  @moduledoc false

  import Rail.Git.Utils.WithCloneLock

  alias Rail.Git
  alias Rail.Projects.Schemas.Project
  alias Rail.Tools

  @timeout_ms to_timeout(minute: 5)

  @doc """
  Fetches `project`'s default branch from `origin` into its clone, with the same credentials Rail pushes with, moves
  the clone's local branch of that name to it, and brings `repo_path` up to it.
  """
  def fetch_default_branch(%Project{} = project, repo_path) when is_binary(repo_path) do
    with {:ok, env} <- Git.credential_env(project) do
      fetch = fn ->
        fetched =
          Tools.run("git", ["fetch", "origin", project.default_branch],
            cd: project.clone_path,
            env: env,
            stderr_to_stdout: true,
            timeout: @timeout_ms
          )

        if match?({_output, 0}, fetched), do: follow_origin(project)
        fetched
      end

      case with_clone_lock(project.clone_path, fetch) do
        {_output, 0} -> Git.copy_default_branch(project, repo_path)
        # coveralls-ignore-next-line (a fetch that runs for five minutes)
        {:error, :timeout} -> {:error, "The fetch was still running after five minutes, so it was stopped."}
        {output, code} when is_binary(output) and is_integer(code) -> {:error, String.trim(output)}
        # coveralls-ignore-next-line (git itself could not be started)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # Agents read the local branch as the default as readily as origin's, and
  # nothing else moves it. The clone is detached so it holds no branch that
  # cannot be moved; one a person checked out elsewhere is left where it is.
  defp follow_origin(%Project{clone_path: clone_path, default_branch: branch}) do
    Tools.run("git", ["checkout", "--quiet", "--detach"], cd: clone_path, stderr_to_stdout: true)
    Tools.run("git", ["branch", "--force", branch, "origin/#{branch}"], cd: clone_path, stderr_to_stdout: true)
  end
end
