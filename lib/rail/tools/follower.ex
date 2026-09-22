defmodule Rail.Tools.Follower do
  @moduledoc """
  Follows a live CLI agent child process by tailing its stream file and monitoring OS PID liveness.

  A Follower that crashes is restarted, and one can be started again for a process
  that lost its Follower some other way. Either picks up where the last left off:
  every batch written to the run's log records how far into the stream it reached,
  in the same transaction, and a Follower starting on a stream already partly
  written replays the lines before that point into its event state without logging
  them again.
  """
  use GenServer, restart: :transient

  import Ecto.Query
  import Rail.Tools.Utils.DecodeUtf8Lenient
  import Rail.Tools.Utils.DrainErrFile
  import Rail.Tools.Utils.GetFollowerPid
  import Rail.Tools.Utils.NewEventState
  import Rail.Tools.Utils.ParseLine
  import Rail.Tools.Utils.PumpStream
  import Rail.Tools.Utils.ReadExitFile

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Repo
  alias Rail.Tools
  alias Rail.Tools.FollowerRegistry
  alias Rail.Tools.Schemas.Backend
  alias Rail.Tools.Schemas.OsProcess

  @default_tail_interval 120
  @default_batch_interval 250

  defstruct [
    :os_process_id,
    :run_id,
    :stream_path,
    :err_path,
    :os_pid,
    :port,
    :event_state,
    :tail_interval_ms,
    :batch_interval_ms,
    :exit_code,
    :deadline_at,
    file_offset: 0,
    logged_offset: 0,
    saved_offset: 0,
    resumed?: false,
    stopped?: false,
    timed_out?: false,
    partial_line: "",
    pending_events: []
  ]

  @doc """
  Starts a new Follower GenServer.

  `os_process` must carry its `run`, preloaded down to `role: :backend` -- the run
  seeds the event state and the backend says what stream format to parse.
  """
  def start_link({%OsProcess{} = os_process, opts}) when is_list(opts) do
    name = {:via, Registry, {FollowerRegistry, os_process.id}}
    GenServer.start_link(__MODULE__, {os_process, opts}, name: name)
  end

  @doc """
  Stops a running process and its follower.
  """
  def stop_os_process(%OsProcess{} = os_process, opts \\ []) do
    case get_follower_pid(os_process.id) do
      pid when is_pid(pid) ->
        try do
          GenServer.call(pid, {:stop_os_process, opts}, 10_000)
          # coveralls-ignore-start (fallback if follower crashes during stop_os_process)
        catch
          :exit, _reason ->
            fallback_stop_os_process(os_process, opts)
            # coveralls-ignore-stop
        end

      nil ->
        fallback_stop_os_process(os_process, opts)
    end
  end

  @impl true
  def init({%OsProcess{} = os_process, opts}) do
    %OsProcess{stream_path: stream_path, run: %Run{role: %{backend: %Backend{} = backend}} = run} = os_process

    tail_interval_ms = Keyword.get(opts, :tail_interval_ms, @default_tail_interval)
    batch_interval_ms = Keyword.get(opts, :batch_interval_ms, @default_batch_interval)

    event_state =
      new_event_state(if(OsProcess.command?(os_process), do: :command, else: backend),
        conversation_id: run.conversation_id
      )

    state = %__MODULE__{
      os_process_id: os_process.id,
      run_id: run.id,
      stream_path: stream_path,
      err_path: "#{stream_path}.err",
      os_pid: os_process.os_pid,
      port: Keyword.get(opts, :port),
      event_state: event_state,
      deadline_at: os_process.deadline_at,
      tail_interval_ms: tail_interval_ms,
      batch_interval_ms: batch_interval_ms
    }

    Process.send_after(self(), :tail_tick, tail_interval_ms)
    Process.send_after(self(), :batch_tick, batch_interval_ms)

    {:ok, state}
  end

  @impl true
  def handle_call({:stop_os_process, opts}, _from, state) do
    if is_integer(state.os_pid) and state.os_pid > 0 do
      Tools.terminate_os_process(state.os_pid, opts)
    end

    state = %{state | exit_code: -1, stopped?: true}
    {updated_os_process, final_state} = do_child_exit(state)
    {:stop, :normal, {:ok, updated_os_process}, final_state}
  end

  # The resume waits for the first tick rather than running in `init/1`: it reads
  # the row, and the process starting a Follower lends it the database only once
  # it has its pid.
  @impl true
  def handle_info(:tail_tick, %__MODULE__{resumed?: false} = state) do
    handle_info(:tail_tick, resume(state))
  end

  def handle_info(:tail_tick, state) do
    {lines, new_offset, new_partial} =
      pump_stream(state.stream_path, state.file_offset, state.partial_line)

    {event_state, pending_events} = process_incoming_lines(lines, state)

    updated_state = %{
      state
      | file_offset: new_offset,
        logged_offset: new_offset - byte_size(new_partial),
        partial_line: new_partial,
        event_state: event_state,
        pending_events: pending_events
    }

    alive? =
      if is_integer(updated_state.os_pid) and updated_state.os_pid > 0 do
        Tools.os_process_alive?(updated_state.os_pid)
      else
        false
      end

    cond do
      alive? and past_deadline?(updated_state) ->
        Tools.terminate_os_process(updated_state.os_pid)
        {_run, final_state} = do_child_exit(%{updated_state | timed_out?: true})
        {:stop, :normal, final_state}

      alive? ->
        Process.send_after(self(), :tail_tick, updated_state.tail_interval_ms)
        {:noreply, updated_state}

      true ->
        {_run, final_state} = do_child_exit(updated_state)
        {:stop, :normal, final_state}
    end
  end

  @impl true
  def handle_info(:batch_tick, state) do
    state = flush_pending_events(state)
    Process.send_after(self(), :batch_tick, state.batch_interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info({_port, {:exit_status, status}}, state) do
    {:noreply, %{state | exit_code: status}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp past_deadline?(%__MODULE__{deadline_at: %DateTime{} = deadline_at}) do
    DateTime.compare(DateTime.utc_now(), deadline_at) != :lt
  end

  defp past_deadline?(%__MODULE__{}), do: false

  defp process_incoming_lines(lines, state) do
    Enum.reduce(lines, {state.event_state, state.pending_events}, fn line, {ev_state, pending} ->
      {parse_line(ev_state, line), [line | pending]}
    end)
  end

  # Pending lines are held newest first, so they are put back in order for the log.
  # The lines and how far they reach are written together: a Follower that dies
  # between the two would otherwise log the same lines again when it comes back.
  defp flush_pending_events(%__MODULE__{pending_events: [], logged_offset: offset, saved_offset: offset} = state) do
    state
  end

  defp flush_pending_events(%__MODULE__{} = state) do
    {:ok, _entries} =
      Repo.transaction(fn ->
        entries = Pipeline.append_run_events(state.run_id, state.os_process_id, Enum.reverse(state.pending_events))

        Repo.update_all(from(o in OsProcess, where: o.id == ^state.os_process_id),
          set: [stream_offset: state.logged_offset]
        )

        entries
      end)

    %{state | pending_events: [], saved_offset: state.logged_offset}
  end

  # Picks up from what the row says was already logged. The lines before that
  # point are replayed into the event state, so what the exit reports (usage, the
  # conversation, a result) covers the whole process, not just what this Follower
  # saw.
  defp resume(%__MODULE__{} = state) do
    offset =
      case Repo.one(from o in OsProcess, where: o.id == ^state.os_process_id, select: o.stream_offset) do
        offset when is_integer(offset) -> offset
        nil -> 0
      end

    event_state =
      state.stream_path
      |> read_logged_lines(offset)
      |> Enum.reduce(state.event_state, &parse_line(&2, &1))

    %{
      state
      | resumed?: true,
        file_offset: offset,
        logged_offset: offset,
        saved_offset: offset,
        event_state: event_state
    }
  end

  defp read_logged_lines(_stream_path, 0), do: []

  defp read_logged_lines(stream_path, offset) do
    with {:ok, handle} <- File.open(stream_path, [:read, :binary]),
         {:ok, bytes} <- :file.pread(handle, 0, offset) do
      File.close(handle)

      bytes
      |> :binary.split("\n", [:global])
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&decode_utf8_lenient/1)
    else
      # coveralls-ignore-start (a stream the row points at that cannot be read)
      _unreadable ->
        []
        # coveralls-ignore-stop
    end
  end

  defp fallback_stop_os_process(os_process, opts) do
    if is_integer(os_process.os_pid) and os_process.os_pid > 0 do
      Tools.terminate_os_process(os_process.os_pid, opts)
    end

    {:ok, updated_os_process} =
      os_process
      |> OsProcess.changeset(%{status: :finished})
      |> Repo.update()

    {:ok, updated_os_process}
  end

  defp do_child_exit(state) do
    state = state |> ensure_resumed() |> await_exit_code()

    {final_lines, final_offset, _remaining_partial} =
      pump_stream(state.stream_path, state.file_offset, state.partial_line, final: true)

    {event_state, pending_events} =
      process_incoming_lines(final_lines, %{state | file_offset: final_offset})

    flush_pending_events(%{state | pending_events: pending_events, logged_offset: final_offset})

    raw_stderr = state.err_path |> drain_err_file() |> Enum.join("\n")

    case Repo.get(OsProcess, state.os_process_id) do
      %OsProcess{} = os_process ->
        {exit_code, error} = settle_exit(state, os_process, event_state, raw_stderr)

        {:ok, updated_os_process} =
          os_process
          |> OsProcess.changeset(%{status: :finished, exit_code: exit_code})
          |> Repo.update()

        updated_run = update_run(state.run_id, event_state)
        outcome = build_outcome(exit_code, error, event_state, updated_os_process, updated_run)

        # Everything that happens next is derived from the row, so a process whose
        # exit this Follower missed settles identically when `Rail.Tools.Boot` finds it.
        Pipeline.run_finished(updated_os_process, outcome)

        Phoenix.PubSub.broadcast(
          Rail.PubSub,
          "run:#{state.run_id}",
          {:os_process_finished, updated_os_process, outcome}
        )

        {updated_os_process, %{state | file_offset: final_offset, pending_events: [], event_state: event_state}}

      nil ->
        {nil, %{state | file_offset: final_offset, pending_events: [], event_state: event_state}}
    end
  end

  # 124, as `timeout(1)` has it: what ran out was time, not a stop someone asked for.
  defp settle_exit(%__MODULE__{timed_out?: true}, %OsProcess{}, _event_state, _raw_stderr) do
    {124, "Timed out, so it was stopped."}
  end

  # A command's output is its log, not an error, so all it has to say about its
  # exit is the status. A Follower resumed after a restart has no port to hear
  # that from, and reads the file the command wrote on its way out.
  defp settle_exit(%__MODULE__{} = state, %OsProcess{kind: kind} = os_process, _event_state, _raw_stderr)
       when kind != :agent do
    exit_code = state.exit_code || read_exit_file(os_process) || -1
    {exit_code, compute_error(nil, "", if(state.stopped?, do: nil, else: exit_code))}
  end

  defp settle_exit(%__MODULE__{} = state, %OsProcess{}, event_state, raw_stderr) do
    error = compute_error(event_state.result_error, raw_stderr, reported_exit_code(state))
    {compute_exit_code(state.exit_code, error, event_state.saw_result), error}
  end

  # A stop can arrive before the first tick has resumed anything.
  defp ensure_resumed(%__MODULE__{resumed?: false} = state), do: resume(state)
  defp ensure_resumed(%__MODULE__{} = state), do: state

  # coveralls-ignore-start (defensive exit status collection for fast-exiting processes)
  defp await_exit_code(%{exit_code: code} = state) when is_integer(code), do: state
  defp await_exit_code(%{port: nil} = state), do: state

  # The status only lands here when it races the stream's end; which one wins is
  # not something a test can arrange.
  defp await_exit_code(state) do
    receive do
      {_port, {:exit_status, status}} ->
        %{state | exit_code: status}
    after
      50 ->
        state
    end
  end

  # coveralls-ignore-stop

  # A run the human stopped exited because it was killed, so its exit code is not
  # news. Anything the agent actually said on the way out still is.
  defp reported_exit_code(%__MODULE__{stopped?: true}), do: nil
  defp reported_exit_code(%__MODULE__{exit_code: exit_code}), do: exit_code

  # The harness says this on its way out when the agent stopped while something it
  # started was still running. On its own it reads as a fault in Rail; what it
  # means is a round that ended early with its own command unread, and the human
  # can put that right with a message.
  @background_task "left a command running in the background and stopped, so the round ended before it read the result"

  defp compute_error(result_error, raw_stderr, exit_code) do
    raw_stderr = if abandoned?(raw_stderr), do: @background_task, else: raw_stderr

    cond do
      is_binary(result_error) and result_error != "" and raw_stderr != "" ->
        "#{result_error}\n#{raw_stderr}"

      is_binary(result_error) and result_error != "" ->
        result_error

      raw_stderr != "" ->
        raw_stderr

      is_integer(exit_code) and exit_code != 0 ->
        "Exited with code #{exit_code}"

      true ->
        nil
    end
  end

  defp abandoned?(raw_stderr) do
    String.contains?(raw_stderr, "background task") and String.contains?(raw_stderr, "terminating")
  end

  # A nil `error` already means no result error and no stderr, so a run that
  # reported a result and never said anything on the way out exited cleanly.
  defp compute_exit_code(exit_code, error, saw_result) do
    cond do
      is_integer(exit_code) and is_nil(error) -> exit_code
      is_integer(exit_code) -> if exit_code == 0, do: 1, else: exit_code
      is_nil(error) and saw_result -> 0
      true -> -1
    end
  end

  # The conversation id is the one thing only the Follower saw, so it is the one
  # thing recorded here, and only the first time: a run is one conversation, and
  # the changeset refuses to move it to another. Everything else about the exit
  # travels in the outcome and is settled by `run_finished/3`, which is what makes
  # the settle identical whether the exit was seen live or found afterwards by
  # `Rail.Tools.Boot`.
  defp update_run(run_id, event_state) do
    case {Pipeline.get_run(run_id), event_state.conversation_id} do
      {{:ok, %Run{conversation_id: nil} = run}, conversation_id} when is_binary(conversation_id) ->
        {:ok, updated_run} = Pipeline.update_run(run, %{conversation_id: conversation_id})
        updated_run

      {{:ok, %Run{} = run}, _already_set_or_unseen} ->
        run

      # coveralls-ignore-start (unreachable due to foreign key cascade delete)
      {{:error, :not_found}, _conversation_id} ->
        nil
        # coveralls-ignore-stop
    end
  end

  defp build_outcome(exit_code, error, event_state, updated_os_process, updated_run) do
    %{
      exit_code: exit_code,
      error: error,
      usage: event_state.usage,
      conversation_id: event_state.conversation_id || (updated_run && updated_run.conversation_id),
      os_process: updated_os_process,
      run: updated_run
    }
  end
end
