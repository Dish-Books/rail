defmodule Rail.Tools.Actions.RunInSandbox do
  @moduledoc """
  Runs a short command where an agent's own process runs: in its task's sandbox,
  through the runner, under Docker; beside Rail under the local runtime.

  What a branch's script does is the branch's, so it runs in the sandbox the
  agent works in rather than with Rail's own reach. It is not a process of the
  run: a run settles when any of its processes exits.
  """

  import Rail.Tools.Utils.DecodeUtf8Lenient
  import Rail.Tools.Utils.Env
  import Rail.Tools.Utils.WorktreeEnv

  alias Rail.Repo
  alias Rail.Tools
  alias Rail.Tools.Clients.Docker
  alias Rail.Tools.RunnerSocket
  alias Rail.Tools.Schemas.OsProcess

  @timeout_ms to_timeout(minute: 2)

  @doc """
  Runs `command` through `/bin/sh` from the worktree root of `os_process`'s task,
  with the worktree's environment, and returns `{:ok, %{output:, exit_code:}}`.

  Takes `:timeout_ms`, two minutes by default, past which it is stopped and
  `{:error, :timeout}` returned.
  """
  def run_in_sandbox(%OsProcess{} = os_process, command, opts \\ []) when is_binary(command) do
    %OsProcess{task: task} = os_process = Repo.preload(os_process, task: :project)
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

  # Not a process of the run, so it has no row: its output comes straight here, and is let go once read.
  defp run(%OsProcess{sandbox_id: sandbox_id}, task, command, timeout_ms) when is_binary(sandbox_id) do
    with conn when is_pid(conn) <- RunnerSocket.whereis(sandbox_id) || {:error, :not_running} do
      id = UXID.generate!(prefix: "exec")
      argv = ["timeout", "-k", "5", "#{timeout_ms / 1000}", "/bin/sh", "-c", command]
      exec = %{"argv" => argv, "env" => env(worktree_env(task)), "cwd" => task.worktree_path, "files" => []}
      RunnerSocket.follow(conn, id, self(), 0, 0, Map.merge(exec, %{"stdin" => nil, "stderr" => "merge"}))
      deadline = System.monotonic_time(:millisecond) + timeout_ms
      result = collect(conn, id, [], 0, deadline)
      RunnerSocket.done(conn, id)
      result
    end
  end

  # A process from before sandboxes ran over the socket has a container of its own.
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

  defp collect(conn, id, output, size, deadline) do
    receive do
      {:runner_data, ^id, 1, offset, bytes} when offset + byte_size(bytes) > size ->
        fresh = binary_part(bytes, size - offset, offset + byte_size(bytes) - size)
        RunnerSocket.ack(conn, id, 1, size + byte_size(fresh))
        collect(conn, id, [output, fresh], size + byte_size(fresh), deadline)

      {:runner_exit, ^id, %{code: code}} ->
        {:ok, %{output: IO.iodata_to_binary(output), exit_code: code}}

      {:runner_failed, ^id, _error} ->
        {:error, :not_running}

      {gone, ^id} when gone in [:runner_lost, :runner_down] ->
        {:error, :not_running}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        send(conn, {:signal, id, "KILL"})
        {:error, :timeout}
    end
  end
end
