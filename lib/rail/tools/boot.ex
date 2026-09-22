defmodule Rail.Tools.Boot do
  @moduledoc """
  Reconciles in-flight runs: at application boot, and every minute after through
  `Rail.Tools.Workers.ReconcileOsProcesses`.

  A process still alive with nobody following it gets a Follower, which resumes
  from what was already logged. A process that died unfollowed is settled here,
  its unlogged lines written to the run's log first. A process that has a
  Follower is left to it, alive or not: the Follower sees its own exit.

  Browser sessions are reaped on the same pass, and for the same reason: a Chrome
  whose session process is gone is a core held until the machine restarts, and its
  row is what stops its task ever getting another browser.
  """
  use Task, restart: :transient

  import Ecto.Query
  import Rail.Tools.Utils.DecodeUtf8Lenient
  import Rail.Tools.Utils.DrainErrFile
  import Rail.Tools.Utils.NewEventState
  import Rail.Tools.Utils.ParseLine
  import Rail.Tools.Utils.ReadExitFile

  alias Ecto.Adapters.SQL.Sandbox
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role
  alias Rail.Tools
  alias Rail.Tools.FollowerSupervisor
  alias Rail.Tools.Schemas.Backend
  alias Rail.Tools.Schemas.OsProcess

  @default_starting_timeout_seconds 60

  @doc """
  Starts the Boot reconciliation task in the supervision tree, unless adoption on
  boot is turned off.
  """
  def start_link(opts \\ []) do
    if Application.get_env(:rail, :adopt_on_boot, true) do
      Task.start_link(__MODULE__, :reconcile, [opts])
    else
      :ignore
    end
  end

  @doc """
  Adopts every in-flight os process, once the runs tables exist.
  """
  def reconcile(opts \\ []) do
    adopted = adopt_live_os_processes(opts)
    _browsers = Tools.reconcile_browser_sessions(opts)

    adopted

    # coveralls-ignore-start (defensive rescue on boot failure)
  rescue
    _error ->
      :ok
      # coveralls-ignore-stop
  end

  defp adopt_live_os_processes(opts) do
    timeout_seconds = Keyword.get(opts, :timeout_seconds, @default_starting_timeout_seconds)
    now = Keyword.get(opts, :now) || DateTime.utc_now()

    os_processes =
      Repo.all(
        from r in OsProcess,
          where: r.status in [:starting, :running],
          preload: [run: [role: :backend]],
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

      os_process.status == :starting and is_nil(os_process.os_pid) ->
        handle_starting_os_process(os_process, now, timeout_seconds)

      is_integer(os_process.os_pid) and os_process.os_pid > 0 and Tools.os_process_alive?(os_process.os_pid) ->
        handle_live_os_process(os_process, opts)

      true ->
        handle_dead_os_process(os_process, now, opts)
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

  defp handle_dead_os_process(os_process, now, _opts) do
    # A stream is parsed by the backend that wrote it, and the row arrives
    # preloaded down to the role that produced the run.
    %Run{role: %Role{backend: %Backend{} = backend}} = run = os_process.run

    event_state =
      new_event_state(if(OsProcess.command?(os_process), do: :command, else: backend),
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

    {exit_code, error} = settle_dead_exit(os_process, updated_event_state, Enum.join(err_lines, "\n"))

    {:ok, updated_os_process} =
      os_process
      |> OsProcess.changeset(%{status: :adopted_dead, exit_code: exit_code})
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

    {:adopted_dead, updated_os_process}
  end

  # A command says how it went only with its status, which it wrote to a file on
  # its way out. One that never wrote it was killed before it could finish.
  defp settle_dead_exit(%OsProcess{kind: kind} = os_process, _event_state, _raw_stderr) when kind != :agent do
    case read_exit_file(os_process) do
      0 -> {0, nil}
      code when is_integer(code) -> {code, "Exited with code #{code}"}
      nil -> {-1, "Ended while Rail was not watching it, without recording how it exited."}
    end
  end

  defp settle_dead_exit(%OsProcess{} = os_process, event_state, raw_stderr) do
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
