defmodule Rail.Git.Actions.FetchBranch do
  @moduledoc false

  import Rail.Git.Utils.WithCloneLock

  alias Rail.Git
  alias Rail.Projects.Schemas.Project
  alias Rail.Tools

  @timeout_ms to_timeout(minute: 5)

  @doc """
  Fetches `branch` from `origin` into `project`'s clone, with the credentials Rail pushes with, and points the
  clone's local branch of that name at it, so a worktree made for it starts from what the remote holds.
  """
  def fetch_branch(%Project{clone_path: clone_path} = project, branch) when is_binary(branch) do
    with {:ok, env} <- Git.credential_env(project) do
      fetch = fn ->
        with {_fetched, 0} <-
               Tools.run("git", ["fetch", "origin", "+refs/heads/#{branch}:refs/remotes/origin/#{branch}"],
                 cd: clone_path,
                 env: env,
                 stderr_to_stdout: true,
                 timeout: @timeout_ms
               ) do
          # No upstream, as for a branch Rail made: pushing names the branch itself.
          Tools.run("git", ["branch", "--force", "--no-track", branch, "origin/#{branch}"],
            cd: clone_path,
            stderr_to_stdout: true
          )
        end
      end

      case with_clone_lock(clone_path, fetch) do
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
