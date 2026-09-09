defmodule Rail.Runs.Follower do
  @moduledoc """
  Follows a live CLI agent child process by tailing its stream file and monitoring OS PID liveness.
  """
  use GenServer, restart: :transient

  import Ecto.Query

  alias Rail.Pipeline
  alias Rail.Repo
  alias Rail.Runs
  alias Rail.Runs.FollowerRegistry
  alias Rail.Runs.Schemas.RoleRun
  alias Rail.Runs.Schemas.Run
  alias Rail.Runs.Schemas.RunEvent
  alias Rail.Runs.Spawner

  @default_tail_interval 120
  @default_batch_interval 250

  defstruct [
    :run_id,
    :role_run_id,
    :task_id,
    :stream_path,
    :err_path,
    :os_pid,
    :port,
    :backend,
    :event_state,
    :tail_interval_ms,
    :batch_interval_ms,
    :on_finished,
    :exit_code,
    file_offset: 0,
    partial_line: "",
    pending_events: [],
    next_seq: 1,
    skip_log_lines: 0
  ]

  @doc """
  Starts a new Follower GenServer.
  """
  def start_link(opts) when is_list(opts) do
    run = Keyword.fetch!(opts, :run)

    name =
      case opts[:name] do
        custom_name when is_tuple(custom_name) or (is_atom(custom_name) and custom_name not in [nil, false]) ->
          custom_name

        _fallback ->
          {:via, Registry, {FollowerRegistry, run.id}}
      end

    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Stops a running process and its follower.
  """
  def stop_run(run_or_id, opts \\ [])

  def stop_run(%Run{} = run, opts) do
    do_stop_run(run, opts)
  end

  def stop_run(id, opts) when is_binary(id) do
    run =
      Repo.get(Run, id) ||
        Repo.one(
          from r in Run,
            where: (r.role_run_id == ^id or r.task_id == ^id) and r.status in [:starting, :running],
            order_by: [desc: r.inserted_at],
            limit: 1
        )

    if run do
      do_stop_run(run, opts)
    else
      {:error, :not_found}
    end
  end

  @doc """
  Reads new bytes appended to the stream file, splits on newline, and yields complete lines.
  """
  def pump_stream(stream_path, file_offset, partial_line, opts \\ []) do
    if File.exists?(stream_path) do
      read_available_stream(stream_path, file_offset, partial_line, opts)
    else
      {[], file_offset, partial_line}
    end
  end

  @doc """
  Reads and decodes the stderr file if present.
  """
  def drain_err_file(err_path) do
    if File.exists?(err_path) do
      case File.read(err_path) do
        {:ok, content} ->
          content
          |> decode_utf8_lenient()
          |> String.split("\n")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        {:error, _read_err} ->
          []
      end
    else
      []
    end
  end

  @doc """
  Decodes binary to UTF-8 leniently, replacing invalid or incomplete byte sequences with replacement characters.
  """
  def decode_utf8_lenient(binary) when is_binary(binary) do
    case :unicode.characters_to_binary(binary, :utf8, :utf8) do
      decoded when is_binary(decoded) ->
        decoded

      {:error, valid, rest} ->
        <<_bad::binary-size(1), tail::binary>> = rest
        valid <> "\uFFFD" <> decode_utf8_lenient(tail)

      {:incomplete, valid, rest} ->
        valid <> String.duplicate("\uFFFD", byte_size(rest))

      # coveralls-ignore-start (defensive unicode fallback)
      _other ->
        binary
        # coveralls-ignore-stop
    end
  end

  @impl true
  def init(opts) do
    run = Keyword.fetch!(opts, :run)
    role_run = Keyword.get(opts, :role_run) || Repo.get!(RoleRun, run.role_run_id)
    stream_path = Keyword.get(opts, :stream_path) || run.stream_path
    backend = Keyword.get(opts, :backend, :claude)
    tail_interval_ms = Keyword.get(opts, :tail_interval_ms, @default_tail_interval)
    batch_interval_ms = Keyword.get(opts, :batch_interval_ms, @default_batch_interval)
    skip_log_lines = Keyword.get(opts, :skip_log_lines, 0)
    file_offset = Keyword.get(opts, :file_offset, 0)

    event_state =
      Runs.new_event_state(backend,
        task_id: run.task_id,
        role_id: role_run.role_id,
        conversation_id: role_run.conversation_id
      )

    next_seq = Keyword.get(opts, :next_seq, 1)

    state = %__MODULE__{
      run_id: run.id,
      role_run_id: role_run.id,
      task_id: run.task_id,
      stream_path: stream_path,
      err_path: "#{stream_path}.err",
      os_pid: Keyword.get(opts, :os_pid) || run.os_pid,
      port: Keyword.get(opts, :port),
      backend: backend,
      event_state: event_state,
      tail_interval_ms: tail_interval_ms,
      batch_interval_ms: batch_interval_ms,
      on_finished: Keyword.get(opts, :on_finished),
      file_offset: file_offset,
      skip_log_lines: skip_log_lines,
      next_seq: next_seq
    }

    Process.send_after(self(), :tail_tick, tail_interval_ms)
    Process.send_after(self(), :batch_tick, batch_interval_ms)

    {:ok, state}
  end

  @impl true
  def handle_call({:stop_run, opts}, _from, state) do
    if is_integer(state.os_pid) and state.os_pid > 0 do
      Spawner.terminate_os_process(state.os_pid, opts)
    end

    state = %{state | exit_code: -1}
    {updated_run, final_state} = do_child_exit(state)
    {:stop, :normal, {:ok, updated_run}, final_state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_info(:tail_tick, state) do
    {lines, new_offset, new_partial} =
      pump_stream(state.stream_path, state.file_offset, state.partial_line)

    {event_state, pending_events, next_seq, skip_log_lines} =
      process_incoming_lines(lines, state)

    updated_state = %{
      state
      | file_offset: new_offset,
        partial_line: new_partial,
        event_state: event_state,
        pending_events: pending_events,
        next_seq: next_seq,
        skip_log_lines: skip_log_lines
    }

    if updated_state.task_id && updated_state.event_state.detected_question &&
         is_nil(state.event_state.detected_question) do
      # Internal helpers
      Pipeline.register_question(
        updated_state.task_id,
        updated_state.role_run_id,
        updated_state.event_state.detected_question
      )
    end

    alive? =
      if is_integer(updated_state.os_pid) and updated_state.os_pid > 0 do
        Spawner.process_alive?(updated_state.os_pid)
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
    state = flush_batch(state)
    Process.send_after(self(), :batch_tick, state.batch_interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info({_port, {:exit_status, status}}, state) do
    {:noreply, %{state | exit_code: status}}
  end

  @impl true
  def handle_info({:EXIT, _port, _reason}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp process_incoming_lines(lines, state) do
    Enum.reduce(
      lines,
      {state.event_state, state.pending_events, state.next_seq, state.skip_log_lines},
      fn line, {ev_state, pending, seq, skip} ->
        new_ev_state = Runs.parse_line(ev_state, line)

        if skip > 0 do
          {new_ev_state, pending, seq, skip - 1}
        else
          {new_ev_state, [{seq, line} | pending], seq + 1, 0}
        end
      end
    )
  end

  defp flush_batch(state) do
    if state.pending_events == [] do
      state
    else
      flush_pending_events(state.pending_events, state.role_run_id)
      %{state | pending_events: []}
    end
  end

  defp flush_pending_events([], _role_run_id), do: []

  defp flush_pending_events(pending_events, role_run_id) do
    now = DateTime.utc_now()

    entries =
      pending_events
      |> Enum.reverse()
      |> Enum.map(fn {seq, line} ->
        %{
          id: UXID.generate!(),
          role_run_id: role_run_id,
          seq: seq,
          line: line,
          inserted_at: now,
          updated_at: now
        }
      end)

    Repo.insert_all(RunEvent, entries)
    Phoenix.PubSub.broadcast(Rail.PubSub, "run:#{role_run_id}", {:run_events, role_run_id, entries})
    entries
  end

  defp do_stop_run(run, opts) do
    case Registry.lookup(FollowerRegistry, run.id) do
      [{pid, _registry_val}] ->
        try do
          GenServer.call(pid, {:stop_run, opts}, 10_000)
          # coveralls-ignore-start (fallback if follower crashes during stop_run)
        catch
          :exit, _reason ->
            fallback_stop_run(run, opts)
            # coveralls-ignore-stop
        end

      [] ->
        fallback_stop_run(run, opts)
    end
  end

  defp fallback_stop_run(run, opts) do
    if is_integer(run.os_pid) and run.os_pid > 0 do
      Spawner.terminate_os_process(run.os_pid, opts)
    end

    {:ok, updated_run} =
      run
      |> Run.changeset(%{status: :finished})
      |> Repo.update()

    {:ok, updated_run}
  end

  defp read_available_stream(stream_path, file_offset, partial_line, opts) do
    case File.stat(stream_path) do
      {:ok, %File.Stat{size: size}} when size > file_offset ->
        read_stream_bytes(stream_path, file_offset, size, partial_line, opts)

      _stat_error ->
        finalize_partial_line(partial_line, file_offset, opts)
    end
  end

  defp read_stream_bytes(stream_path, file_offset, size, partial_line, opts) do
    case File.open(stream_path, [:read, :binary]) do
      {:ok, handle} ->
        :file.position(handle, file_offset)
        result = :file.read(handle, size - file_offset)
        File.close(handle)
        handle_stream_read(result, size, file_offset, partial_line, opts)

      # coveralls-ignore-start (defensive file open error fallback)
      _open_error ->
        {[], file_offset, partial_line}

        # coveralls-ignore-stop
    end
  end

  defp handle_stream_read({:ok, bytes}, size, _file_offset, partial_line, opts) do
    combined = partial_line <> bytes
    parts = :binary.split(combined, "\n", [:global])
    {complete_lines, [new_partial]} = Enum.split(parts, length(parts) - 1)

    {final_lines, remaining_partial} =
      if Keyword.get(opts, :final, false) and new_partial != "" do
        {Enum.reverse([new_partial | Enum.reverse(complete_lines)]), ""}
      else
        {complete_lines, new_partial}
      end

    {Enum.map(final_lines, &decode_utf8_lenient/1), size, remaining_partial}
  end

  # coveralls-ignore-start (defensive file read error fallback)
  defp handle_stream_read(_read_error, _size, file_offset, partial_line, _opts) do
    {[], file_offset, partial_line}
  end

  # coveralls-ignore-stop

  defp finalize_partial_line(partial_line, file_offset, opts) do
    if Keyword.get(opts, :final, false) and partial_line != "" do
      {[decode_utf8_lenient(partial_line)], file_offset, ""}
    else
      {[], file_offset, partial_line}
    end
  end

  defp do_child_exit(state) do
    state = await_exit_code(state)

    {final_lines, final_offset, _remaining_partial} =
      pump_stream(state.stream_path, state.file_offset, state.partial_line, final: true)

    {event_state, pending_events, _next_seq, _skip} =
      process_incoming_lines(final_lines, %{state | file_offset: final_offset})

    err_lines = drain_err_file(state.err_path)
    flush_pending_events(pending_events, state.role_run_id)

    raw_stderr =
      err_lines
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    error = compute_error(event_state.result_error, raw_stderr, state.exit_code)

    exit_code =
      compute_exit_code(
        state.exit_code,
        error,
        event_state.saw_result,
        event_state.result_error,
        raw_stderr
      )

    if state.task_id && event_state.detected_question do
      Pipeline.register_question(
        state.task_id,
        state.role_run_id,
        event_state.detected_question
      )
    end

    case Repo.get(Run, state.run_id) do
      %Run{} = run ->
        {:ok, updated_run} =
          run
          |> Run.changeset(%{status: :finished})
          |> Repo.update()

        updated_role_run = update_role_run(state.role_run_id, exit_code, error, event_state)
        outcome = build_outcome(exit_code, error, event_state, updated_run, updated_role_run)

        notify_run_finished(state.on_finished, updated_run, outcome)

        Phoenix.PubSub.broadcast(
          Rail.PubSub,
          "run:#{state.role_run_id}",
          {:run_finished, updated_run, outcome}
        )

        {updated_run, %{state | file_offset: final_offset, pending_events: [], event_state: event_state}}

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

  defp compute_exit_code(exit_code, error, saw_result, result_error, raw_stderr) do
    cond do
      is_integer(exit_code) and is_nil(error) ->
        exit_code

      is_integer(exit_code) ->
        if exit_code == 0, do: 1, else: exit_code

      saw_result and is_nil(result_error) and raw_stderr == "" ->
        0

      true ->
        -1
    end
  end

  defp update_role_run(role_run_id, exit_code, error, event_state) do
    case Repo.get(RoleRun, role_run_id) do
      %RoleRun{} = role_run ->
        new_status =
          if role_run.status == :blocked_on_input do
            :blocked_on_input
          else
            :finished
          end

        role_run_attrs = %{
          status: new_status,
          completed_at: DateTime.utc_now(),
          exit_code: exit_code,
          error: error,
          output: event_state.final_text,
          usage: event_state.usage,
          conversation_id: event_state.conversation_id || role_run.conversation_id
        }

        {:ok, updated_role_run} =
          role_run
          |> RoleRun.changeset(role_run_attrs)
          |> Repo.update()

        updated_role_run

      # coveralls-ignore-start (unreachable due to foreign key cascade delete)
      nil ->
        nil
        # coveralls-ignore-stop
    end
  end

  defp build_outcome(exit_code, error, event_state, updated_run, updated_role_run) do
    %{
      exit_code: exit_code,
      error: error,
      output: event_state.final_text,
      usage: event_state.usage,
      conversation_id: event_state.conversation_id || (updated_role_run && updated_role_run.conversation_id),
      detected_question: event_state.detected_question,
      run: updated_run,
      role_run: updated_role_run
    }
  end

  defp notify_run_finished(on_finished, updated_run, outcome) do
    if is_function(on_finished, 2) do
      on_finished.(updated_run, outcome)
    else
      Runs.on_run_finished(updated_run, outcome)
    end
  end
end
