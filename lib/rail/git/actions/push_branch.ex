defmodule Rail.Git.Actions.PushBranch do
  @moduledoc """
  Pushes a task's branch to `origin`.

  The credential is minted here from the project's GitHub App installation rather
  than passed in: a token is not something a caller should be holding, and the
  installation is what keeps a branch pushable after whoever was assigned leaves.

  Forced, because a rebased branch no longer extends what the remote has, but
  only over what Rail has itself seen and built on: a push made outside Rail is
  refused rather than overwritten.

  The repository's own pre-push hooks run. A project whose CI runs before Rail
  pushes leaves a record a hook can recognise, so they should cost nothing; one
  that still runs for longer than it may is stopped.
  """

  alias Rail.Git
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Tools

  @timeout_ms to_timeout(minute: 10)

  @doc """
  Pushes `task`'s branch, setting it to track `origin`.
  """
  def push_branch(%Scope{}, %Task{} = task) do
    with {:ok, env} <- Git.credential_env(Repo.get!(Project, task.project_id)) do
      push(task.worktree_path, task.worktree_name, env)
    end
  end

  defp push(worktree_path, branch, env) do
    case Tools.run("git", ["push", "--force-with-lease", "--force-if-includes", "--set-upstream", "origin", branch],
           cd: worktree_path,
           env: env,
           stderr_to_stdout: true,
           timeout: @timeout_ms
         ) do
      {_output, 0} -> :ok
      # coveralls-ignore-next-line (a hook that runs for ten minutes)
      {:error, :timeout} -> {:error, "The push was still running after ten minutes, so it was stopped."}
      {output, code} when is_binary(output) and is_integer(code) -> {:error, String.trim(output)}
      # coveralls-ignore-next-line (git itself could not be started)
      {:error, reason} -> {:error, reason}
    end
  end
end
