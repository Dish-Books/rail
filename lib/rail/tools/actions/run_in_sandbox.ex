defmodule Rail.Tools.Actions.RunInSandbox do
  @moduledoc """
  Runs a short command where an agent's own process runs: inside its container
  under Docker, beside Rail under the local runtime.

  What a branch's script does is the branch's, so it runs in the sandbox the
  agent works in rather than with Rail's own reach. It is not a process of the
  run: a run settles when any of its processes exits.
  """

  import Rail.Tools.Utils.DecodeUtf8Lenient
  import Rail.Tools.Utils.WorktreeEnv

  alias Rail.Repo
  alias Rail.Tools
  alias Rail.Tools.Clients.Docker
  alias Rail.Tools.Schemas.OsProcess

  @timeout_ms to_timeout(minute: 2)

  @doc """
  Runs `command` through `/bin/sh` from the worktree root of `os_process`'s task,
  with the worktree's environment, and returns `{:ok, %{output:, exit_code:}}`.

  Takes `:timeout_ms`, two minutes by default, past which it is stopped and
  `{:error, :timeout}` returned.
  """
  def run_in_sandbox(%OsProcess{} = os_process, command, opts \\ []) when is_binary(command) do
    %OsProcess{task: task} = os_process = Repo.preload(os_process, :task)
    timeout_ms = Keyword.get(opts, :timeout_ms, @timeout_ms)

    os_process
    |> run(task, command, timeout_ms)
    |> case do
      {:ok, %{output: output, exit_code: exit_code}} ->
        {:ok, %{output: decode_utf8_lenient(output), exit_code: exit_code}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run(%OsProcess{runtime: :docker, container_id: container_id}, task, command, timeout_ms)
       when is_binary(container_id) do
    # Rail stopping its wait does not stop an exec, so the container kills the command at the same limit.
    argv = ["timeout", "-k", "5", "#{timeout_ms / 1000}", "/bin/sh", "-c", command]
    exec = Task.async(fn -> Docker.exec_in_container(container_id, argv, worktree_env(task), task.worktree_path) end)

    case Task.yield(exec, timeout_ms) || Task.shutdown(exec, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, :timeout}
    end
  end

  defp run(%OsProcess{runtime: :local}, task, command, timeout_ms) do
    case Tools.run("/bin/sh", ["-c", command],
           cd: task.worktree_path,
           env: worktree_env(task),
           stderr_to_stdout: true,
           timeout: timeout_ms
         ) do
      {:error, reason} -> {:error, reason}
      {output, exit_code} -> {:ok, %{output: output, exit_code: exit_code}}
    end
  end
end
