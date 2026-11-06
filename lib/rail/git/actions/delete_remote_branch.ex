defmodule Rail.Git.Actions.DeleteRemoteBranch do
  @moduledoc false

  import Rail.Git.Utils.WithCloneLock

  alias Rail.Git
  alias Rail.Projects.Schemas.Project
  alias Rail.Tools

  @timeout_ms to_timeout(minute: 5)

  @doc """
  Deletes `branch` from `origin` with the credentials Rail pushes with. A branch the remote does not have,
  such as one never pushed, counts as deleted.
  """
  def delete_remote_branch(%Project{clone_path: clone_path} = project, branch) when is_binary(branch) do
    with {:ok, env} <- Git.credential_env(project) do
      push = fn ->
        Tools.run("git", ["push", "origin", "--delete", branch],
          cd: clone_path,
          env: env,
          stderr_to_stdout: true,
          timeout: @timeout_ms
        )
      end

      case with_clone_lock(clone_path, push) do
        {_output, 0} ->
          :ok

        # coveralls-ignore-next-line (a delete that runs for five minutes)
        {:error, :timeout} ->
          {:error, "The delete was still running after five minutes, so it was stopped."}

        {output, code} when is_binary(output) and is_integer(code) ->
          if output =~ "remote ref does not exist", do: :ok, else: {:error, String.trim(output)}

        # coveralls-ignore-next-line (git itself could not be started)
        {:error, reason} ->
          {:error, reason}
      end
    end
  end
end
