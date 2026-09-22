defmodule Rail.Tools.Actions.StartCommandProcess do
  @moduledoc false

  import Rail.Tools.Utils.WorktreeEnv

  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Tools
  alias Rail.Tools.FollowerSupervisor
  alias Rail.Tools.Schemas.OsProcess

  # perl rather than setsid, which macOS does not ship: leading its own process
  # group is what lets a stop take down everything the command started.
  @perl "/usr/bin/perl"
  @group_leader "setpgrp(0, 0); exec @ARGV or die $!"
  @exit_var "__RAIL_EXIT_PATH"
  @default_timeout_ms to_timeout(minute: 30)

  @doc """
  Runs `command` through `/bin/sh` in `run`'s worktree as an OS process of `kind`,
  followed like an agent's and settled by `run_finished/3` when it exits.

  Takes `:timeout_ms`, after which it is stopped, and `:env`. Returns
  `{:ok, os_process}` with `:run` and `:task` loaded, or `{:error, reason}`.
  """
  def start_command_process(%Run{} = run, kind, command, opts \\ []) when is_binary(command) do
    %Run{task: %Task{} = task} = run = Repo.preload(run, [:task, role: :backend])
    os_process = insert_os_process(run, kind, command, Keyword.get(opts, :timeout_ms, @default_timeout_ms))

    env =
      task
      |> worktree_env()
      |> Map.merge(Keyword.get(opts, :env, %{}))
      |> Map.put(@exit_var, OsProcess.exit_path(os_process))

    spawn_opts = [
      stdout_path: os_process.stream_path,
      stderr_path: os_process.stream_path,
      cd: task.worktree_path,
      env: env
    ]

    case Tools.spawn_os_process(@perl, ["-e", @group_leader, "/bin/sh", "-c", script(command)], spawn_opts) do
      {:ok, port, os_pid} ->
        os_process = os_process |> OsProcess.changeset(%{status: :running, os_pid: os_pid}) |> Repo.update!()
        follow(%{os_process | run: run, task: task}, port)

      # A command quick enough to be gone before its pid could be read has already
      # written how it exited, which is all its Follower needs to settle it.
      {:error, :no_os_pid} ->
        os_process = os_process |> OsProcess.changeset(%{status: :running}) |> Repo.update!()
        follow(%{os_process | run: run, task: task}, nil)

      {:error, reason} ->
        os_process |> OsProcess.changeset(%{status: :failed}) |> Repo.update!()
        {:error, reason}
    end
  end

  # The status goes to a file as well as the port, because the port dies with the
  # BEAM and a command outlives it. A subshell, so a command that exits still gets it written.
  defp script(command) do
    "(\n#{command}\n)\nstatus=$?\necho $status > \"$#{@exit_var}\"\nexit $status\n"
  end

  defp insert_os_process(%Run{} = run, kind, command, timeout_ms) do
    id = UXID.generate!(prefix: "proc")
    stream_path = Path.join([run.task.scratch_path, "streams", "#{id}.log"])
    stream_path |> Path.dirname() |> File.mkdir_p!()
    File.write!(stream_path, "")
    now = DateTime.utc_now()

    %OsProcess{id: id}
    |> OsProcess.changeset(%{
      run_id: run.id,
      task_id: run.task_id,
      kind: kind,
      command: command,
      stream_path: stream_path,
      status: :starting,
      started_at: now,
      deadline_at: DateTime.add(now, timeout_ms, :millisecond)
    })
    |> Repo.insert!()
  end

  defp follow(%OsProcess{} = os_process, port) do
    with {:ok, _follower_pid} <- FollowerSupervisor.start_follower(os_process, port: port) do
      {:ok, os_process}
    end
  end
end
