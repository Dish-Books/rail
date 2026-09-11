defmodule Rail.Runs.Actions.StartRun do
  @moduledoc false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Rail.Backends.Schemas.Backend
  alias Rail.Repo
  alias Rail.Runs.FollowerSupervisor
  alias Rail.Runs.Schemas.RoleRun
  alias Rail.Runs.Schemas.Run
  alias Rail.Runs.Schemas.RunEvent
  alias Rail.Tools

  @doc """
  Spawns a detached CLI runner for a role run, records the `runs` row, and
  starts its Follower.

  Derives the executable, arguments and environment, creates the stream files,
  inserts the `runs` row as `:starting`, hands the spawn off to
  `Rail.Tools.spawn_run/3`, then records the OS PID as `:running`.
  """
  def start_run(role_run_or_id, kind, argv, opts \\ [])

  def start_run(%RoleRun{} = role_run, kind, argv, opts) do
    do_start_run(role_run, kind, argv, opts)
  end

  def start_run(role_run_id, kind, argv, opts) when is_binary(role_run_id) do
    RoleRun
    |> Repo.get!(role_run_id)
    |> do_start_run(kind, argv, opts)
  end

  defp do_start_run(role_run, kind, argv, opts) do
    backend = Keyword.fetch!(opts, :backend)
    {executable, args} = executable_and_args(argv, backend, opts)
    stream_path = stream_path(role_run, opts)
    prepare_stream_files(stream_path)

    run = insert_run(role_run, kind, stream_path)
    resolved_binary = Tools.resolve(executable)

    if binary_exists?(resolved_binary) do
      launch(run, role_run, resolved_binary, args, stream_path, backend, opts)
    else
      settle_missing_binary(run, role_run, executable)
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

    {:ok, run} =
      %Run{}
      |> Run.changeset(attrs)
      |> Repo.insert()

    run
  end

  defp executable_and_args(argv, backend, opts) do
    case Keyword.get(opts, :executable) do
      exe when is_binary(exe) and exe != "" ->
        {exe, argv}

      _other ->
        case argv do
          [first | rest] when is_binary(first) ->
            if String.starts_with?(first, "/") or File.exists?(first) do
              {first, rest}
            else
              {backend_executable(backend), argv}
            end

          _other ->
            {backend_executable(backend), []}
        end
    end
  end

  defp backend_executable(%Backend{executable_path: path}) when is_binary(path), do: path
  defp backend_executable(_unconfigured), do: ""

  defp stream_path(role_run, opts) do
    case Keyword.get(opts, :stream_path) do
      path when is_binary(path) and path != "" ->
        path

      _other ->
        state_dir =
          Keyword.get(opts, :state_dir) ||
            System.get_env("RAIL_STATE_DIR") ||
            Path.join(System.tmp_dir!(), "rail")

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

  defp launch(run, role_run, executable, args, stream_path, backend, opts) do
    spawn_opts = [
      env: run_env(stream_path, opts),
      stdout_path: stream_path,
      stderr_path: "#{stream_path}.err",
      cd:
        Keyword.get(opts, :cd) ||
          Keyword.get(opts, :working_directory) ||
          Keyword.get(opts, :work_dir)
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
    if Keyword.get(opts, :skip_follower, Application.get_env(:rail, :skip_follower, false)) do
      Tools.connect_port(port, nil)
      {:ok, run}
    else
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
          allow_sandbox(follower_pid, opts)
          allow_test_mocks(follower_pid, opts)
          Tools.connect_port(port, follower_pid)
          {:ok, run}

        # coveralls-ignore-start (defensive error handling if follower supervisor fails)
        {:error, reason} ->
          {:error, reason}
          # coveralls-ignore-stop
      end
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

  defp run_env(stream_path, opts) do
    scratch_path = Keyword.get(opts, :scratch_path) || Keyword.get(opts, :rail_scratch) || ""
    gh_token = Keyword.get(opts, :gh_token) || System.get_env("GH_TOKEN") || ""

    env =
      Map.merge(
        %{
          "RAIL_STREAM" => stream_path,
          "RAIL_STREAM_ERR" => "#{stream_path}.err",
          "RAIL_SCRATCH" => scratch_path,
          "GH_TOKEN" => gh_token
        },
        Keyword.get(opts, :env, %{})
      )

    case Keyword.get(opts, :credential_helper) do
      helper when is_binary(helper) and helper != "" ->
        Map.put(env, "GIT_ASKPASS", helper)

      _other ->
        env
    end
  end

  defp settle_missing_binary(run, role_run, executable) do
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

  # coveralls-ignore-start (test sandbox fallback)
  defp allow_sandbox(pid, opts) do
    owner = Keyword.get(opts, :test_pid, self())

    if Code.ensure_loaded?(Sandbox) do
      Sandbox.allow(Repo, owner, pid)
    end
  rescue
    _error -> :ok
  end

  defp allow_test_mocks(pid, opts) do
    owner = Keyword.get(opts, :test_pid, self())

    if Code.ensure_loaded?(Req.Test) do
      try do
        Req.Test.allow(Rail.GitHub, owner, pid)
      rescue
        _error -> :ok
      end

      try do
        Req.Test.allow(Rail.Linear, owner, pid)
      rescue
        _error -> :ok
      end
    end
  rescue
    _error -> :ok
  end

  # coveralls-ignore-stop
end
