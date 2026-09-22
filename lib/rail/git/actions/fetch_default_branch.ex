defmodule Rail.Git.Actions.FetchDefaultBranch do
  @moduledoc false

  alias Rail.Git
  alias Rail.Projects.Schemas.Project
  alias Rail.Tools

  @timeout_ms to_timeout(minute: 5)

  @doc """
  Fetches `project`'s default branch from `origin` into the worktree at
  `worktree_path`, with the same credentials Rail pushes with.
  """
  def fetch_default_branch(%Project{} = project, worktree_path) when is_binary(worktree_path) do
    with {:ok, env} <- Git.credential_env(project) do
      case Tools.run("git", ["fetch", "origin", project.default_branch],
             cd: worktree_path,
             env: env,
             stderr_to_stdout: true,
             timeout: @timeout_ms
           ) do
        {_output, 0} -> :ok
        # coveralls-ignore-next-line (a fetch that runs for five minutes)
        {:error, :timeout} -> {:error, "The fetch was still running after five minutes, so it was stopped."}
        {output, code} when is_binary(output) and is_integer(code) -> {:error, String.trim(output)}
        # coveralls-ignore-next-line (git itself could not be started)
        {:error, reason} -> {:error, reason}
      end
    end
  end
end
