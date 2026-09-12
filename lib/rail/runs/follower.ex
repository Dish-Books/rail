defmodule Rail.Runs.Follower do
  @moduledoc """
  Follows a live CLI agent child process by tailing its stream file and monitoring OS PID liveness.
  """
  use GenServer, restart: :temporary

  import Rail.Runs.Utils.DrainErrFile
  import Rail.Runs.Utils.GetFollowerPid
  import Rail.Runs.Utils.NewEventState
  import Rail.Runs.Utils.ParseLine
  import Rail.Runs.Utils.PumpStream

  alias Rail.Backends.Schemas.Backend
  alias Rail.Pipeline
  alias Rail.Repo
  alias Rail.Runs.FollowerRegistry
  alias Rail.Runs.Schemas.OsProcess
  alias Rail.Runs.Schemas.Run
  alias Rail.Runs.Schemas.RunEvent
  alias Rail.Tools

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
    file_offset: 0,
    partial_line: "",
    pending_events: [],
    skip_log_lines: 0
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
    skip_log_lines = Keyword.get(opts, :skip_log_lines, 0)
    file_offset = Keyword.get(opts, :file_offset, 0)

    event_state =
      new_event_state(backend,
        task_id: os_process.task_id,
        role_id: run.role_id,
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
      tail_interval_ms: tail_interval_ms,
      batch_interval_ms: batch_interval_ms,
      file_offset: file_offset,
      skip_log_lines: skip_log_lines
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

    state = %{state | exit_code: -1}
    {updated_os_process, final_state} = do_child_exit(state)
    {:stop, :normal, {:ok, updated_os_process}, final_state}
  end

  @impl true
  def handle_info(:tail_tick, state) do
    {lines, new_offset, new_partial} =
      pump_stream(state.stream_path, state.file_offset, state.partial_line)

    {event_state, pending_events, skip_log_lines} =
      process_incoming_lines(lines, state)

    updated_state = %{
      state
      | file_offset: new_offset,
        partial_line: new_partial,
        event_state: event_state,
        pending_events: pending_events,
        skip_log_lines: skip_log_lines
    }

    alive? =
      if is_integer(updated_state.os_pid) and updated_state.os_pid > 0 do
        Tools.os_process_alive?(updated_state.os_pid)
      else
        false
      end

    if alive? do
      Process.send_after(self(), :tail_tick, updated_state.tail_interval_ms)
      {:noreply, updated_state}
    else
      {_run, final_state} = do_child_exit(updated_state)
      {:stop, :normal, final_state}
    end
  end

  @impl true
  def handle_info(:batch_tick, state) do
    flush_pending_events(state.pending_events, state.run_id, state.os_process_id)
    Process.send_after(self(), :batch_tick, state.batch_interval_ms)
    {:noreply, %{state | pending_events: []}}
  end

  @impl true
  def handle_info({_port, {:exit_status, status}}, state) do
    {:noreply, %{state | exit_code: status}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp process_incoming_lines(lines, state) do
    Enum.reduce(
      lines,
      {state.event_state, state.pending_events, state.skip_log_lines},
      fn line, {ev_state, pending, skip} ->
        new_ev_state = parse_line(ev_state, line)

        if skip > 0 do
          {new_ev_state, pending, skip - 1}
        else
          {new_ev_state, [line | pending], 0}
        end
      end
    )
  end

  defp flush_pending_events([], _run_id, _os_process_id), do: []

  # `seq` is left to the database: it orders the run's whole log, and this process
  # is not the only writer appending to it.
  defp flush_pending_events(pending_events, run_id, os_process_id) do
    now = DateTime.utc_now()

    entries =
      pending_events
      |> Enum.reverse()
      |> Enum.map(fn line ->
        %{
          id: UXID.generate!(),
          run_id: run_id,
          os_process_id: os_process_id,
          line: line,
          inserted_at: now,
          updated_at: now
        }
      end)

    Repo.insert_all(RunEvent, entries)
    Phoenix.PubSub.broadcast(Rail.PubSub, "run:#{run_id}", {:run_events, run_id, entries})
    entries
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
    state = await_exit_code(state)

    {final_lines, final_offset, _remaining_partial} =
      pump_stream(state.stream_path, state.file_offset, state.partial_line, final: true)

    {event_state, pending_events, _skip} =
      process_incoming_lines(final_lines, %{state | file_offset: final_offset})

    flush_pending_events(pending_events, state.run_id, state.os_process_id)

    raw_stderr = state.err_path |> drain_err_file() |> Enum.join("\n")
    error = compute_error(event_state.result_error, raw_stderr, state.exit_code)
    exit_code = compute_exit_code(state.exit_code, error, event_state.saw_result)

    case Repo.get(OsProcess, state.os_process_id) do
      %OsProcess{} = os_process ->
        {:ok, updated_os_process} =
          os_process
          |> OsProcess.changeset(%{status: :finished})
          |> Repo.update()

        updated_run = update_run(state.run_id, exit_code, error, event_state, os_process.is_chat)
        outcome = build_outcome(exit_code, error, event_state, updated_os_process, updated_run)

        # Everything that happens next is derived from the row, so a process whose
        # exit this Follower missed settles identically when `Rail.Runs.Boot` finds it.
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

  # coveralls-ignore-start (defensive exit status collection for fast-exiting processes)
  defp await_exit_code(%{exit_code: code} = state) when is_integer(code), do: state
  defp await_exit_code(%{port: nil} = state), do: state

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

  defp compute_error(result_error, raw_stderr, exit_code) do
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

  defp update_run(run_id, exit_code, error, event_state, is_chat) do
    case Repo.get(Run, run_id) do
      %Run{} = run ->
        run_attrs =
          if is_chat do
            conv_id = event_state.conversation_id || run.conversation_id

            if conv_id == run.conversation_id do
              %{}
            else
              %{conversation_id: conv_id}
            end
          else
            new_status =
              if run.status == :blocked_on_input do
                :blocked_on_input
              else
                :finished
              end

            %{
              status: new_status,
              completed_at: DateTime.utc_now(),
              exit_code: exit_code,
              error: error,
              conversation_id: event_state.conversation_id || run.conversation_id,
              usage: event_state.usage
            }
          end

        {:ok, updated_run} =
          run
          |> Run.changeset(run_attrs)
          |> Repo.update()

        updated_run

      # coveralls-ignore-start (unreachable due to foreign key cascade delete)
      nil ->
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
      detected_questions: event_state.detected_questions,
      os_process: updated_os_process,
      run: updated_run
    }
  end
end
