defmodule Rail.Runs.Spawner do
  @moduledoc """
  Spawns detached CLI agent runner processes with file-redirected I/O.
  """

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Rail.Repo
  alias Rail.Runs.ArgvBuilder
  alias Rail.Runs.FollowerSupervisor
  alias Rail.Runs.Schemas.RoleRun
  alias Rail.Runs.Schemas.Run
  alias Rail.ToolEnv

  @doc """
  Spawns a detached child process for an agent run.

  Steps:
  1. Derives executable, arguments, and environment.
  2. Creates stream files.
  3. Inserts `runs` row with `status: :starting`.
  4. Spawns detached child via `/bin/sh` with HUP/INT trapped and output redirected.
  5. Obtains OS PID from Port and updates `runs` row with `status: :running` and `os_pid`.
  6. Starts a `Follower` under `FollowerSupervisor` and connects port ownership.
  """
  def spawn_run(role_run_or_id, kind, argv, opts \\ [])

  def spawn_run(%RoleRun{} = role_run, kind, argv, opts) do
    do_spawn_run(role_run, kind, argv, opts)
  end

  def spawn_run(role_run_id, kind, argv, opts) when is_binary(role_run_id) do
    role_run = Repo.get!(RoleRun, role_run_id)
    do_spawn_run(role_run, kind, argv, opts)
  end

  @doc """
  Checks whether an OS process with the given PID is alive via `kill -0 <pid>`.
  """
  def process_alive?(pid) when is_integer(pid) and pid > 0 do
    case System.cmd("kill", ["-0", to_string(pid)], stderr_to_stdout: true, env: %{}) do
      {_output, 0} -> true
      {_output, _code} -> false
    end

    # coveralls-ignore-start (defensive rescue if kill binary is missing)
  rescue
    _error ->
      false
      # coveralls-ignore-stop
  end

  def process_alive?(_other), do: false

  @doc """
  Terminates an OS process with SIGTERM, waiting up to grace period,
  and escalates to SIGKILL if necessary.
  """
  def terminate_os_process(pid, opts \\ [])

  def terminate_os_process(pid, opts) when is_integer(pid) and pid > 0 do
    grace_period = Keyword.get(opts, :grace_period, 500)
    kill_cmd("TERM", pid)

    if wait_until_dead(pid, grace_period) do
      :ok
    else
      kill_cmd("KILL", pid)
      wait_until_dead(pid, 500)
      :ok
    end
  end

  def terminate_os_process(_other, _opts), do: :ok

  defp do_spawn_run(role_run, kind, argv, opts) do
    backend = Keyword.get(opts, :backend, :claude)
    {executable, args} = resolve_executable_and_args(argv, backend, opts)
    stream_path = resolve_stream_path(role_run, opts)
    prepare_stream_files(stream_path)

    run_attrs = %{
      role_run_id: role_run.id,
      task_id: role_run.task_id,
      kind: kind,
      stream_path: stream_path,
      node: to_string(Node.self()),
      boot_id: Rail.Runs.boot_id(),
      status: :starting,
      started_at: DateTime.utc_now()
    }

    {:ok, run} =
      %Run{}
      |> Run.changeset(run_attrs)
      |> Repo.insert()

    resolved_binary = ToolEnv.resolve(executable)

    if binary_exists?(resolved_binary) do
      launch_and_follow(run, role_run, resolved_binary, args, stream_path, backend, opts)
    else
      handle_missing_binary(run, role_run, executable)
    end
  end

  defp resolve_executable_and_args(argv, backend, opts) do
    case Keyword.get(opts, :executable) do
      exe when is_binary(exe) and exe != "" ->
        {exe, argv}

      _other ->
        case argv do
          [first | rest] when is_binary(first) ->
            if String.starts_with?(first, "/") or File.exists?(first) do
              {first, rest}
            else
              {ArgvBuilder.executable_path(backend, opts), argv}
            end

          _other ->
            {ArgvBuilder.executable_path(backend, opts), []}
        end
    end
  end

  defp resolve_stream_path(role_run, opts) do
    case Keyword.get(opts, :stream_path) do
      path when is_binary(path) and path != "" ->
        path

      _other ->
        state_dir =
          Keyword.get(opts, :state_dir) ||
            System.get_env("AXIS_STATE_DIR") ||
            Path.join(System.tmp_dir!(), "axis")

        streams_dir = Path.join(state_dir, "streams")
        File.mkdir_p!(streams_dir)
        identifier = role_run.task_id || role_run.id
        Path.join(streams_dir, "#{identifier}.ndjson")
    end
  end

  defp prepare_stream_files(stream_path) do
    stream_path |> Path.dirname() |> File.mkdir_p!()
    File.write!(stream_path, "")
    File.write!("#{stream_path}.err", "")
    :ok
  end

  defp binary_exists?(path) do
    File.exists?(path) and not File.dir?(path)
  end

  defp launch_and_follow(run, role_run, executable, args, stream_path, backend, opts) do
    env_list = build_environment(stream_path, opts)
    sh_script = ~s(trap "" HUP INT; exec "$0" "$@" </dev/null >>"$AXIS_STREAM" 2>>"$AXIS_STREAM_ERR")
    port_args = ["-c", sh_script, executable | args]

    cd =
      Keyword.get(opts, :cd) ||
        Keyword.get(opts, :working_directory) ||
        Keyword.get(opts, :work_dir)

    base_opts = [:binary, :exit_status, args: port_args, env: env_list]
    port_opts = if is_binary(cd) and cd != "", do: [{:cd, cd} | base_opts], else: base_opts

    port = Port.open({:spawn_executable, "/bin/sh"}, port_opts)

    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} when is_integer(os_pid) ->
        {:ok, updated_run} =
          run
          |> Run.changeset(%{status: :running, os_pid: os_pid})
          |> Repo.update()

        if Keyword.get(opts, :skip_follower, false) do
          Process.unlink(port)
          {:ok, updated_run}
        else
          max_seq =
            Repo.one(
              from e in Rail.Runs.Schemas.RunEvent,
                where: e.role_run_id == ^role_run.id,
                select: max(e.seq)
            ) || 0

          follower_opts = [
            run: updated_run,
            role_run: role_run,
            stream_path: stream_path,
            os_pid: os_pid,
            port: port,
            backend: backend,
            next_seq: max_seq + 1,
            on_finished: Keyword.get(opts, :on_finished)
          ]

          case FollowerSupervisor.start_follower(follower_opts) do
            {:ok, follower_pid} ->
              allow_sandbox(follower_pid)

              # coveralls-ignore-start (defensive rescue if port terminates before connect)
              try do
                Port.connect(port, follower_pid)
                Process.unlink(port)
              rescue
                _error -> :ok
              end

              # coveralls-ignore-stop

              {:ok, updated_run}

            # coveralls-ignore-start (defensive error handling if follower supervisor fails)
            {:error, reason} ->
              {:error, reason}
          end
        end

      _other ->
        {:error, :no_os_pid}
        # coveralls-ignore-stop
    end
  end

  # coveralls-ignore-start (test sandbox fallback)
  defp allow_sandbox(pid) do
    if Code.ensure_loaded?(Sandbox) do
      Sandbox.allow(Repo, self(), pid)
    end
  rescue
    _error -> :ok
  end

  defp build_environment(stream_path, opts) do
    scratch_path =
      Keyword.get(opts, :scratch_path) ||
        Keyword.get(opts, :axis_scratch) ||
        ""

    gh_token =
      Keyword.get(opts, :gh_token) ||
        System.get_env("GH_TOKEN") ||
        ""

    extra_env =
      Map.merge(
        %{
          "AXIS_STREAM" => stream_path,
          "AXIS_STREAM_ERR" => "#{stream_path}.err",
          "AXIS_SCRATCH" => scratch_path,
          "GH_TOKEN" => gh_token
        },
        Keyword.get(opts, :env, %{})
      )

    extra_env =
      case Keyword.get(opts, :credential_helper) do
        helper when is_binary(helper) and helper != "" ->
          Map.put(extra_env, "GIT_ASKPASS", helper)

        # coveralls-ignore-stop

        _other ->
          extra_env
      end

    merged = ToolEnv.env(extra_env)

    Enum.map(merged, fn {k, v} ->
      {String.to_charlist(to_string(k)), String.to_charlist(to_string(v))}
    end)
  end

  defp handle_missing_binary(run, role_run, executable) do
    error_msg = "No such CLI binary: #{executable}"

    {:ok, updated_run} =
      run
      |> Run.changeset(%{status: :finished})
      |> Repo.update()

    {:ok, _updated_role_run} =
      role_run
      |> RoleRun.changeset(%{
        status: :finished,
        completed_at: DateTime.utc_now(),
        exit_code: -1,
        error: error_msg
      })
      |> Repo.update()

    {:error, {:missing_binary, executable, updated_run}}
  end

  defp kill_cmd(signal, pid) do
    System.cmd("kill", ["-#{signal}", to_string(pid)], stderr_to_stdout: true, env: %{})
    # coveralls-ignore-start (defensive rescue if kill fails)
  rescue
    _error ->
      :ok
      # coveralls-ignore-stop
  end

  defp wait_until_dead(pid, timeout_ms) do
    poll_interval = 20
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until_dead(pid, deadline, poll_interval)
  end

  defp do_wait_until_dead(pid, deadline, poll_interval) do
    if process_alive?(pid) do
      if System.monotonic_time(:millisecond) >= deadline do
        false
      else
        Process.sleep(poll_interval)
        do_wait_until_dead(pid, deadline, poll_interval)
      end
    else
      true
    end
  end
end
