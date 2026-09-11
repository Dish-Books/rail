defmodule Rail.Runs.Actions.StartRun do
  @moduledoc false

  import Ecto.Query
  import Rail.Runs.Utils.EnsureExecutable

  alias Rail.Backends.Schemas.Backend
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role
  alias Rail.Runs.FollowerSupervisor
  alias Rail.Runs.Schemas.RoleRun
  alias Rail.Runs.Schemas.Run
  alias Rail.Runs.Schemas.RunEvent
  alias Rail.Tools

  @doc """
  Spawns a detached CLI runner for a role run, records the `runs` row, and
  starts its Follower.

  Everything the spawn needs is derived from the role run: the executable from
  its role's backend, which is an absolute path, and the working directory and
  stream path from its task.
  `argv` is arguments only. The only options are `:on_finished`, the callback
  the Follower invokes when the child exits, and `:allow_fun`, a 1-arity
  function called with the Follower pid so a test can grant it access to
  sandboxed resources.
  """
  def start_run(%RoleRun{} = role_run, kind, argv, opts \\ []) do
    role_run = Repo.preload(role_run, [:task, role: :backend])
    %RoleRun{task: %Task{} = task, role: %Role{backend: %Backend{} = backend}} = role_run

    executable = backend.executable_path
    stream_path = prepare_stream_files(task, role_run)
    run = insert_run(role_run, kind, stream_path)

    case ensure_executable(executable, run, role_run) do
      :ok -> launch(run, role_run, executable, argv, stream_path, task, backend, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_run(role_run, kind, stream_path) do
    attrs = %{
      role_run_id: role_run.id,
      task_id: role_run.task_id,
      kind: kind,
      stream_path: stream_path,
      node: to_string(Node.self()),
      status: :starting,
      started_at: DateTime.utc_now()
    }

    %Run{}
    |> Run.changeset(attrs)
    |> Repo.insert!()
  end

  # One stream per run, under the task's scratch directory, so concurrent runs
  # on a task cannot truncate each other's logs.
  defp prepare_stream_files(%Task{scratch_path: scratch_path}, %RoleRun{id: id}) do
    stream_path = Path.join([scratch_path, "streams", "#{id}.ndjson"])
    stream_path |> Path.dirname() |> File.mkdir_p!()
    File.write!(stream_path, "")
    File.write!("#{stream_path}.err", "")
    stream_path
  end

  defp launch(run, role_run, executable, args, stream_path, task, backend, opts) do
    spawn_opts = [
      env: run_env(stream_path),
      stdout_path: stream_path,
      stderr_path: "#{stream_path}.err",
      cd: task.worktree_path
    ]

    case Tools.spawn_run(executable, args, spawn_opts) do
      {:ok, port, os_pid} ->
        {:ok, updated_run} =
          run
          |> Run.changeset(%{status: :running, os_pid: os_pid})
          |> Repo.update()

        follow(updated_run, role_run, port, os_pid, stream_path, backend, opts)

      # coveralls-ignore-start (defensive: port died before reporting a PID)
      {:error, reason} ->
        {:error, reason}
        # coveralls-ignore-stop
    end
  end

  defp follow(run, role_run, port, os_pid, stream_path, backend, opts) do
    follower_opts = [
      run: run,
      role_run: role_run,
      stream_path: stream_path,
      os_pid: os_pid,
      port: port,
      backend: backend,
      next_seq: next_seq(role_run),
      on_finished: Keyword.get(opts, :on_finished)
    ]

    case FollowerSupervisor.start_follower(follower_opts) do
      {:ok, follower_pid} ->
        allow(follower_pid, opts)
        Tools.connect_port(port, follower_pid)
        {:ok, run}

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

  defp next_seq(role_run) do
    max_seq =
      Repo.one(
        from e in RunEvent,
          where: e.role_run_id == ^role_run.id,
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
