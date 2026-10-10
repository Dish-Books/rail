defmodule Rail.Git.Actions.PushBranch do
  @moduledoc """
  Pushes a task's branch to `origin`.

  The credential is minted here from the project's GitHub App installation rather
  than passed in: a token is not something a caller should be holding, and the
  installation is what keeps a branch pushable after whoever was assigned leaves.

  The agent keeps its branch up to date itself, by a merge or a rebase, and a
  rebased branch no longer extends what the remote has. A push git refuses is
  tried once more with a lease, which overwrites only what Rail last pushed there,
  so a remote holding work Rail never saw is still refused.

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

  defp push(worktree_path, branch, env, force \\ []) do
    case Tools.run("git", ["push" | force] ++ ["--set-upstream", "origin", branch],
           cd: worktree_path,
           env: env,
           stderr_to_stdout: true,
           timeout: @timeout_ms
         ) do
      {_output, 0} ->
        :ok

      {output, code} when is_binary(output) and is_integer(code) and force == [] ->
        if output =~ "[rejected]",
          do: push(worktree_path, branch, env, ["--force-with-lease"]),
          else: {:error, String.trim(output)}

      # coveralls-ignore-next-line (a hook that runs for ten minutes)
      {:error, :timeout} ->
        {:error, "The push was still running after ten minutes, so it was stopped."}

      {output, code} when is_binary(output) and is_integer(code) ->
        {:error, String.trim(output)}

      # coveralls-ignore-next-line (git itself could not be started)
      {:error, reason} ->
        {:error, reason}
    end
  end
end
