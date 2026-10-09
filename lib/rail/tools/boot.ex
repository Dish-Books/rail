defmodule Rail.Tools.Boot do
  @moduledoc """
  Reconciles in-flight runs: at application boot, and every minute after through
  `Rail.Tools.Workers.ReconcileOsProcesses`.

  A process still alive with nobody following it gets a Follower, which resumes
  from what was already logged. A process that died unfollowed is settled here,
  its unlogged lines written to the run's log first. A process that has a
  Follower is left to it, alive or not: the Follower sees its own exit.

  Browser sessions are reconciled on the same pass: the shared Chrome outlives
  Rail, so a tab whose task has moved on is closed here, and one a running pass
  is still using is reconnected to.
  """
  use Task, restart: :transient

  import Ecto.Query
  import Rail.Tools.Utils.AdmitSandboxes
  import Rail.Tools.Utils.DecodeUtf8Lenient
  import Rail.Tools.Utils.DrainErrFile
  import Rail.Tools.Utils.NewEventState
  import Rail.Tools.Utils.ParseLine
  import Rail.Tools.Utils.ReadExitFile
  import Rail.Tools.Utils.RemoveSandbox
  import Rail.Tools.Utils.SandboxState

  alias Ecto.Adapters.SQL.Sandbox
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role
  alias Rail.Tools
  alias Rail.Tools.Clients.Docker
  alias Rail.Tools.FollowerSupervisor
  alias Rail.Tools.Schemas.OsProcess
  alias Rail.Tools.Schemas.ToolchainInstall
  alias Rail.Tools.Workers.InstallToolchain

  @default_starting_timeout_seconds 60
  @label "dev.railai.sandbox"

  @doc """
  Starts the Boot reconciliation task in the supervision tree, unless adoption on
  boot is turned off.
  """
  def start_link(opts \\ []) do
    if Rail.adopt_on_boot?() do
      Task.start_link(__MODULE__, :reconcile, [Keyword.put(opts, :boot, true)])
    else
      :ignore
    end
  end

  @doc """
  Adopts every in-flight os process, once the runs tables exist, then starts
  whatever now fits in the line and removes containers whose rows have settled.
  With `boot: true`, a toolchain install the last BEAM left unsettled is queued again.
  """
  def reconcile(opts \\ []) do
    if Keyword.get(opts, :boot, false), do: requeue_toolchain_installs()
    adopted = adopt_live_os_processes(opts)
    _browsers = Tools.reconcile_browser_sessions(opts)
    _admitted = admit_sandboxes()
    remove_settled_containers()

    adopted

    # coveralls-ignore-start (defensive rescue on boot failure)
  rescue
    _error ->
      :ok
      # coveralls-ignore-stop
  end

  # Only as Rail boots: whatever was running one went down with the BEAM.
  defp requeue_toolchain_installs do
    for id <- Repo.all(from i in ToolchainInstall, where: i.status in [:queued, :installing], select: i.id) do
      {:ok, _job} = %{install_id: id} |> InstallToolchain.new() |> Oban.insert()
    end
  end

  defp adopt_live_os_processes(opts) do
    timeout_seconds = Keyword.get(opts, :timeout_seconds, @default_starting_timeout_seconds)
    now = Keyword.get(opts, :now) || DateTime.utc_now()

    os_processes =
      Repo.all(
        from r in OsProcess,
          where: r.status in [:starting, :running],
          preload: [run: :role],
          order_by: [asc: r.started_at]
      )

    Enum.map(os_processes, fn os_process ->
      adopt_single_os_process(os_process, now, timeout_seconds, opts)
    end)
  end

  defp adopt_single_os_process(os_process, now, timeout_seconds, opts) do
    follower = Registry.lookup(Rail.Tools.FollowerRegistry, os_process.id)

    cond do
      match?([{_pid, _value}], follower) ->
        [{pid, _value}] = follower
        {:already_following, os_process, pid}

      os_process.status == :starting and is_nil(os_process.os_pid) and is_nil(os_process.container_id) ->
        handle_starting_os_process(os_process, now, timeout_seconds)

      true ->
        adopt_sandbox(os_process, sandbox_state(os_process), now, opts)
    end
  end

  # Asked of whatever it runs in, so a container that outlived Rail is adopted like
  # any other, and one that exited meanwhile settles on how it exited.
  defp adopt_sandbox(os_process, :running, _now, opts), do: handle_live_os_process(os_process, opts)

  defp adopt_sandbox(os_process, {:exited, exit_code, oom_killed?}, now, _opts),
    do: handle_dead_os_process(os_process, {exit_code, oom_killed?}, now)

  defp adopt_sandbox(os_process, :gone, now, _opts), do: handle_dead_os_process(os_process, nil, now)

  # A container is removed by its Follower once its run settles; this catches any
  # whose Follower never got to, and any whose row is gone.
  defp remove_settled_containers do
    with :docker <- Rail.sandbox_runtime(),
         {:ok, containers} <- Docker.list_containers(@label) do
      ids = Enum.map(containers, & &1["Labels"][@label])

      in_flight =
        Repo.all(
          from p in OsProcess,
            where: p.id in ^ids and p.status in [:waiting_for_resources, :starting, :running],
            select: p.id
        )

      # Forced, since a settled row's container can still be running: a stop that
      # never reached Docker, or a launch Rail went down in the middle of.
      for container <- containers, container["Labels"][@label] not in in_flight do
        Docker.remove_container(container["Id"], force: true)
      end
    end
  end

  defp handle_starting_os_process(os_process, now, timeout_seconds) do
    started_at = os_process.started_at || os_process.inserted_at
    diff = DateTime.diff(now, started_at, :second)

    if diff > timeout_seconds do
      {:ok, updated_os_process} =
        os_process
        |> OsProcess.changeset(%{status: :finished})
        |> Repo.update()

      if os_process.run do
        error_msg = "Spawn timed out: process never acquired a PID after #{diff}s"

        {:ok, _updated_run} =
          Pipeline.update_run(os_process.run, %{
            status: :finished,
            completed_at: now,
            exit_code: -1,
            error: error_msg
          })
      end

      {:failed_starting, updated_os_process}
    else
      {:still_starting, os_process}
    end
  end

  defp handle_live_os_process(os_process, _opts) do
    case FollowerSupervisor.start_follower(os_process) do
      {:ok, follower_pid} ->
        allow_sandbox(follower_pid)
        {:adopted_live, os_process, follower_pid}

      # coveralls-ignore-start (follower supervisor start failure)
      {:error, reason} ->
        {:error, os_process, reason}
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

  defp handle_dead_os_process(os_process, exited, now) do
    # A stream is parsed by the CLI that wrote it, and the row arrives
    # preloaded down to the role that produced the run.
    %Run{role: %Role{cli: cli}} = run = os_process.run

    event_state =
      new_event_state(if(OsProcess.command?(os_process), do: :command, else: cli),
        conversation_id: run.conversation_id
      )

    {lines, unlogged_lines, err_lines} = read_entire_stream_and_err(os_process.stream_path, os_process.stream_offset)

    # Nobody wrote these to the run's log while the process was alive, so the
    # conversation would otherwise end wherever its last Follower stopped.
    if run, do: Pipeline.append_run_events(run.id, os_process.id, unlogged_lines)

    updated_event_state =
      Enum.reduce(lines, event_state, fn line, acc ->
        parse_line(acc, line)
      end)

    {exit_code, error} = settle_dead_exit(os_process, updated_event_state, Enum.join(err_lines, "\n"), exited)

    {:ok, updated_os_process} =
      os_process
      |> OsProcess.changeset(%{
        status: :adopted_dead,
        exit_code: exit_code,
        ended_at: now,
        ended_reason: ended_reason(exited, exit_code)
      })
      |> Repo.update()

    if run do
      run_attrs = %{
        status: :finished,
        completed_at: now,
        exit_code: exit_code,
        error: error,
        usage: updated_event_state.usage,
        conversation_id: updated_event_state.conversation_id || run.conversation_id
      }

      {:ok, updated_run} = Pipeline.update_run(run, run_attrs)

      outcome = %{
        exit_code: exit_code,
        error: error,
        usage: updated_event_state.usage,
        conversation_id: updated_event_state.conversation_id || run.conversation_id,
        os_process: updated_os_process,
        run: updated_run
      }

      # A process adopted dead settles exactly as one Rail watched exit: the row
      # says which task and run it belonged to and whether it was a chat turn.
      Pipeline.run_finished(updated_os_process, outcome)

      # coveralls-ignore-stop
      Phoenix.PubSub.broadcast(Rail.PubSub, "run:#{run.id}", {:os_process_finished, updated_os_process, outcome})
    end

    remove_sandbox(updated_os_process)

    {:adopted_dead, updated_os_process}
  end

  defp ended_reason({_exit_code, true}, _code), do: :out_of_memory
  defp ended_reason(_exited, 137), do: :killed
  defp ended_reason(_exited, _code), do: :finished

  defp settle_dead_exit(%OsProcess{reserved_memory_gb: memory_gb}, _event_state, _raw_stderr, {_exit_code, true}) do
    {137, "Killed: it used more than the #{memory_gb} GB its role reserves."}
  end

  # A command says how it went with its status, which it wrote to a file on its
  # way out, or its container kept. One that has neither was killed before it could finish.
  defp settle_dead_exit(%OsProcess{kind: kind} = os_process, _event_state, _raw_stderr, exited) when kind != :agent do
    case read_exit_file(os_process) || with({exit_code, _oom} <- exited, do: exit_code) do
      0 -> {0, nil}
      code when is_integer(code) -> {code, "Exited with code #{code}"}
      nil -> {-1, "Ended while Rail was not watching it, without recording how it exited."}
    end
  end

  # A container says how it exited, so an agent that ended without a result is
  # settled on that rather than on a guess.
  defp settle_dead_exit(%OsProcess{}, event_state, raw_stderr, {exit_code, false}) do
    error =
      cond do
        is_binary(event_state.result_error) and event_state.result_error != "" and raw_stderr != "" ->
          "#{event_state.result_error}\n#{raw_stderr}"

        is_binary(event_state.result_error) and event_state.result_error != "" ->
          event_state.result_error

        raw_stderr != "" ->
          raw_stderr

        exit_code != 0 ->
          "Exited with code #{exit_code}"

        true ->
          nil
      end

    {if(is_nil(error) or exit_code != 0, do: exit_code, else: 1), error}
  end

  defp settle_dead_exit(%OsProcess{} = os_process, event_state, raw_stderr, nil) do
    error = compute_dead_error(event_state.result_error, raw_stderr, event_state.saw_result, os_process.os_pid)
    {compute_dead_exit_code(event_state.saw_result, event_state.result_error, raw_stderr), error}
  end

  defp compute_dead_error(result_error, raw_stderr, saw_result, os_pid) do
    cond do
      is_binary(result_error) and result_error != "" and raw_stderr != "" ->
        "#{result_error}\n#{raw_stderr}"

      is_binary(result_error) and result_error != "" ->
        result_error

      raw_stderr != "" ->
        raw_stderr

      saw_result ->
        nil

      true ->
        "Reattached to pid #{os_pid || "unknown"}, which ended without reporting a result."
    end
  end

  defp compute_dead_exit_code(saw_result, result_error, raw_stderr) do
    if saw_result and is_nil(result_error) and raw_stderr == "" do
      0
    else
      -1
    end
  end

  # Every line, for the event state, and the lines past what was already logged.
  defp read_entire_stream_and_err(stream_path, logged_offset) do
    binary =
      case File.read(stream_path) do
        {:ok, binary} -> binary
        {:error, _missing} -> ""
      end

    logged_offset = min(logged_offset || 0, byte_size(binary))
    unlogged = binary_part(binary, logged_offset, byte_size(binary) - logged_offset)

    err_lines = drain_err_file("#{stream_path}.err")
    {stream_lines(binary), stream_lines(unlogged), err_lines}
  end

  defp stream_lines(binary) do
    binary
    |> decode_utf8_lenient()
    |> String.split("\n")
    |> Enum.reject(&(&1 == ""))
  end
end
