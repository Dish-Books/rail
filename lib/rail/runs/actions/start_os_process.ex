defmodule Rail.Runs.Actions.StartOsProcess do
  @moduledoc false

  import Ecto.Query
  import Rail.Runs.Utils.EnsureExecutable

  alias Rail.Backends.Schemas.Backend
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role
  alias Rail.Runs.FollowerSupervisor
  alias Rail.Runs.Schemas.OsProcess
  alias Rail.Runs.Schemas.Run
  alias Rail.Runs.Schemas.RunEvent
  alias Rail.Tools

  @doc """
  Spawns a detached CLI runner for a run, records the `runs` row, starts its
  Follower, and settles the dispatch either way.

  Everything the spawn needs is derived from the run: the executable from
  its role's backend, which is an absolute path, and the working directory and
  stream path from its task.
  `argv` is arguments only. The options are `:is_chat`, which marks a chat turn
  riding alongside the stage rather than the stage's own run, and `:allow_fun`, a
  1-arity function called with the Follower pid so a test can grant it access to
  sandboxed resources. Nothing is wired in for the exit: `run_finished/3` works
  from the row the spawn writes.

  Returns `{:ok, %{task: task, run: run, os_process: os_process}}`, or
  `{:error, {:spawn_failed, reason, task}}`. A stage spawn is the dispatch of
  the task's stage, so it carries the task with it: on success the task moves to
  `:running` with the run's pending answer cleared, on failure to `:failed` with
  the reason recorded, and either way `pipeline_changed` is broadcast. A chat
  turn rides alongside the stage and leaves the task alone.
  """
  def start_os_process(%Run{} = run, argv, opts \\ []) do
    run = Repo.preload(run, [:task, role: :backend])
    %Run{task: %Task{} = task, role: %Role{backend: %Backend{} = backend}} = run

    is_chat = Keyword.get(opts, :is_chat, false)
    executable = backend.executable_path
    stream_path = prepare_stream_files(task, run)
    os_process = insert_os_process(run, is_chat, stream_path)

    result =
      case ensure_executable(executable, os_process, run) do
        :ok -> launch(os_process, run, executable, argv, stream_path, task, backend, opts)
        {:error, reason} -> {:error, reason}
      end

    case result do
      {:ok, os_process} -> finalize(is_chat, task, run, os_process)
      {:error, reason} -> fail(is_chat, task, reason)
    end
  end

  defp finalize(false, task, run, os_process) do
    {:ok, run} =
      run
      |> Run.changeset(%{pending_answer: nil, attempt_log_lines: 0})
      |> Repo.update()

    {:ok, task} = task |> Task.changeset(%{stage_state: :running}) |> Repo.update()

    Pipeline.broadcast_pipeline_changed(%{task_id: task.id, event: :dispatched})

    {:ok, %{task: task, run: run, os_process: os_process}}
  end

  defp finalize(true, task, run, os_process) do
    {:ok, %{task: task, run: run, os_process: os_process}}
  end

  defp fail(false, task, reason) do
    {:ok, task} =
      task
      |> Task.changeset(%{stage_state: :failed, error: "Failed to spawn runner: #{inspect(reason)}"})
      |> Repo.update()

    Pipeline.broadcast_pipeline_changed(%{task_id: task.id, event: :dispatch_failed})

    {:error, {:spawn_failed, reason, task}}
  end

  defp fail(true, task, reason), do: {:error, {:spawn_failed, reason, task}}

  defp insert_os_process(run, is_chat, stream_path) do
    attrs = %{
      run_id: run.id,
      task_id: run.task_id,
      is_chat: is_chat,
      start_seq: next_seq(run),
      stream_path: stream_path,
      node: to_string(Node.self()),
      status: :starting,
      started_at: DateTime.utc_now()
    }

    %OsProcess{}
    |> OsProcess.changeset(attrs)
    |> Repo.insert!()
  end

  # One stream per run, under the task's scratch directory, so concurrent runs
  # on a task cannot truncate each other's logs.
  defp prepare_stream_files(%Task{scratch_path: scratch_path}, %Run{id: id}) do
    stream_path = Path.join([scratch_path, "streams", "#{id}.ndjson"])
    stream_path |> Path.dirname() |> File.mkdir_p!()
    File.write!(stream_path, "")
    File.write!("#{stream_path}.err", "")
    stream_path
  end

  defp launch(os_process, run, executable, args, stream_path, task, backend, opts) do
    spawn_opts = [
      env: run_env(stream_path),
      stdout_path: stream_path,
      stderr_path: "#{stream_path}.err",
      cd: task.worktree_path
    ]

    case Tools.spawn_os_process(executable, args, spawn_opts) do
      {:ok, port, os_pid} ->
        {:ok, updated_run} =
          os_process
          |> OsProcess.changeset(%{status: :running, os_pid: os_pid})
          |> Repo.update()

        follow(updated_run, run, port, os_pid, stream_path, backend, opts)

      # coveralls-ignore-start (defensive: port died before reporting a PID)
      {:error, reason} ->
        {:error, reason}
        # coveralls-ignore-stop
    end
  end

  defp follow(os_process, run, port, os_pid, stream_path, backend, opts) do
    follower_opts = [
      os_process: os_process,
      run: run,
      stream_path: stream_path,
      os_pid: os_pid,
      port: port,
      backend: backend,
      next_seq: os_process.start_seq
    ]

    case FollowerSupervisor.start_follower(follower_opts) do
      {:ok, follower_pid} ->
        allow(follower_pid, opts)
        Tools.connect_port(port, follower_pid)
        {:ok, os_process}

      # coveralls-ignore-start (defensive error handling if follower supervisor fails)
      {:error, reason} ->
        {:error, reason}
        # coveralls-ignore-stop
    end
  end

  defp allow(follower_pid, opts) do
    case Keyword.get(opts, :allow_fun) do
      fun when is_function(fun, 1) -> fun.(follower_pid)
      _none -> :ok
    end
  end

  defp next_seq(run) do
    max_seq =
      Repo.one(
        from e in RunEvent,
          where: e.run_id == ^run.id,
          select: max(e.seq)
      ) || 0

    max_seq + 1
  end

  # The agent is told its scratch directory by absolute path in the brief, so the
  # child only needs the stream files and a token.
  defp run_env(stream_path) do
    %{
      "RAIL_STREAM" => stream_path,
      "RAIL_STREAM_ERR" => "#{stream_path}.err",
      "GH_TOKEN" => System.get_env("GH_TOKEN") || ""
    }
  end
end
