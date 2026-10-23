defmodule Rail.Git.Actions.TrackRemoteBranch do
  @moduledoc """
  Takes a branch as `origin` has it, for a pull request Rail works on as it was pushed rather than cutting its own.
  """

  import Rail.Git.Utils.WithCloneLock

  alias Rail.Git
  alias Rail.Projects.Schemas.Project
  alias Rail.Tools

  @timeout_ms to_timeout(minute: 5)

  @doc """
  Fetches `branch` from `origin` and points the clone's local branch of that name at it, tracking it, so the worktree
  made from it starts at what was pushed with nothing unpushed. Returns `:ok` or `{:error, output}`.
  """
  def track_remote_branch(%Project{clone_path: clone_path} = project, branch) when is_binary(branch) do
    with {:ok, env} <- Git.credential_env(project) do
      with_clone_lock(clone_path, fn ->
        with {_fetched, 0} <-
               Tools.run("git", ["fetch", "--quiet", "origin", "+refs/heads/#{branch}:refs/remotes/origin/#{branch}"],
                 cd: clone_path,
                 env: env,
                 stderr_to_stdout: true,
                 timeout: @timeout_ms
               ),
             # Forced, since a branch left in the clone by earlier work is older than what was pushed.
             {_tracked, 0} <-
               Tools.run("git", ["branch", "--force", "--track", branch, "origin/#{branch}"],
                 cd: clone_path,
                 stderr_to_stdout: true
               ) do
          :ok
        else
          {output, code} when is_binary(output) and is_integer(code) -> {:error, String.trim(output)}
          # coveralls-ignore-next-line (a fetch that runs for five minutes, or git itself could not be started)
          {:error, reason} -> {:error, inspect(reason)}
        end
      end)
    end
  end
end
