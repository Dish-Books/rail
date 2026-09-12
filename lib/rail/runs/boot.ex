defmodule Rail.Runs.Boot do
  @moduledoc """
  Reconciles in-flight runs at application boot.
  """
  use Task, restart: :transient

  import Ecto.Query

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias Rail.Backends.Schemas.Backend
  alias Rail.Pipeline
  alias Rail.Repo
  alias Rail.Runs
  alias Rail.Runs.Follower
  alias Rail.Runs.FollowerSupervisor
  alias Rail.Runs.Schemas.OsProcess
  alias Rail.Runs.Schemas.Run
  alias Rail.Tools

  @default_starting_timeout_seconds 60

  @doc """
  Starts the Boot reconciliation task in the supervision tree.
  """
  def start_link(opts \\ []) do
    Task.start_link(__MODULE__, :reconcile, [opts])
  end

  @doc """
  Runs adoption if runs tables exist and adoption is enabled.
  """
  def reconcile(opts \\ []) do
    if Application.get_env(:rail, :adopt_on_boot, true) and tables_exist?() do
      adopt_live_os_processes(opts)
    else
      :ok
    end

    # coveralls-ignore-start (defensive rescue on boot failure)
  rescue
    _error ->
      :ok
      # coveralls-ignore-stop
  end

  @doc """
  Adopts all in-flight runs on the current node.
  """
  def adopt_live_os_processes(opts \\ []) do
    current_node = Keyword.get(opts, :node) || to_string(Node.self())
    timeout_seconds = Keyword.get(opts, :timeout_seconds, @default_starting_timeout_seconds)
    now = Keyword.get(opts, :now) || DateTime.utc_now()

    os_processes =
      Repo.all(
        from r in OsProcess,
          where: r.node == ^current_node and r.status in [:starting, :running],
          preload: [:run],
          order_by: [asc: r.started_at]
      )

    Enum.map(os_processes, fn os_process ->
      adopt_single_os_process(os_process, now, timeout_seconds, opts)
    end)
  end

  defp adopt_single_os_process(os_process, now, timeout_seconds, opts) do
    cond do
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
          os_process.run
          |> Run.changeset(%{
            status: :finished,
            completed_at: now,
            exit_code: -1,
            error: error_msg
          })
          |> Repo.update()
      end

      {:failed_starting, updated_os_process}
    else
      {:still_starting, os_process}
    end
  end

  defp handle_live_os_process(os_process, _opts) do
    case Registry.lookup(Rail.Runs.FollowerRegistry, os_process.id) do
      [{pid, _val}] ->
        {:already_following, os_process, pid}

      [] ->
        max_seq =
          if os_process.run do
            Repo.one(
              from e in Rail.Runs.Schemas.RunEvent,
                where: e.run_id == ^os_process.run.id,
                select: max(e.seq)
            ) || 0
          else
            0
          end

        follower_opts = [
          os_process: os_process,
          run: os_process.run,
          stream_path: os_process.stream_path,
          os_pid: os_process.os_pid,
          next_seq: max_seq + 1,
          skip_log_lines: (os_process.run && os_process.run.attempt_log_lines) || 0,
          backend: backend_for(os_process.run)
        ]

        case FollowerSupervisor.start_follower(follower_opts) do
          {:ok, follower_pid} ->
            allow_sandbox(follower_pid)
            {:adopted_live, os_process, follower_pid}

          # coveralls-ignore-start (follower supervisor start failure)
          {:error, reason} ->
            {:error, os_process, reason}
            # coveralls-ignore-stop
        end
    end
  end

  # A stream is parsed by the backend that wrote it, so adoption reads the backend off
  # the role that produced the run rather than guessing.
  defp backend_for(%Run{} = run) do
    case Repo.preload(run, role: :backend) do
      %Run{role: %{backend: %Backend{} = backend}} -> backend
      _unconfigured -> %Backend{name: :claude}
    end
  end

  defp backend_for(_run), do: %Backend{name: :claude}

  # coveralls-ignore-start (test sandbox fallback)
  defp allow_sandbox(pid) do
    if Code.ensure_loaded?(Sandbox) do
      Sandbox.allow(Repo, self(), pid)
    end
  rescue
    _error -> :ok
  end

  defp handle_dead_os_process(os_process, now, _opts) do
    run = os_process.run || Repo.get(Run, os_process.run_id)
    backend = backend_for(run)

    event_state =
      Runs.new_event_state(backend,
        task_id: os_process.task_id,
        role_id: (run && run.role_id) || "",
        conversation_id: run && run.conversation_id
      )

    {lines, err_lines} = read_entire_stream_and_err(os_process.stream_path)

    updated_event_state =
      Enum.reduce(lines, event_state, fn line, acc ->
        Runs.parse_line(acc, line)
      end)

    raw_stderr =
      err_lines
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    error =
      compute_dead_error(
        updated_event_state.result_error,
        raw_stderr,
        updated_event_state.saw_result,
        os_process.os_pid
      )

    exit_code =
      compute_dead_exit_code(
        updated_event_state.saw_result,
        updated_event_state.result_error,
        raw_stderr
      )

    {:ok, updated_os_process} =
      os_process
      |> OsProcess.changeset(%{status: :adopted_dead})
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

      {:ok, updated_run} =
        run
        |> Run.changeset(run_attrs)
        |> Repo.update()

      outcome = %{
        exit_code: exit_code,
        error: error,
        usage: updated_event_state.usage,
        conversation_id: updated_event_state.conversation_id || run.conversation_id,
        detected_questions: updated_event_state.detected_questions,
        os_process: updated_os_process,
        run: updated_run
      }

      # A process adopted dead settles exactly as one this node watched exit: the row
      # says which task and run it belonged to and whether it was a chat turn.
      Pipeline.run_finished(updated_os_process, outcome)

      # coveralls-ignore-stop
      Runs.on_os_process_finished(updated_os_process, outcome)

      Phoenix.PubSub.broadcast(Rail.PubSub, "run:#{run.id}", {:os_process_finished, updated_os_process, outcome})
    end

    {:adopted_dead, updated_os_process}
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

  defp read_entire_stream_and_err(stream_path) do
    lines =
      if File.exists?(stream_path) do
        case File.read(stream_path) do
          {:ok, binary} ->
            binary
            |> Follower.decode_utf8_lenient()
            |> String.split("\n")
            |> Enum.reject(&(&1 == ""))

          # coveralls-ignore-start (defensive read failure)
          _error ->
            []
            # coveralls-ignore-stop
        end
      else
        []
      end

    err_lines = Follower.drain_err_file("#{stream_path}.err")
    {lines, err_lines}
  end

  defp tables_exist? do
    SQL.table_exists?(Repo, "runs") and
      SQL.table_exists?(Repo, "runs")

    # coveralls-ignore-start (defensive rescue if db connection fails during boot)
  rescue
    _error ->
      false
      # coveralls-ignore-stop
  end
end
