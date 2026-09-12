defmodule Rail.Runs.Follower do
  @moduledoc """
  Follows a live CLI agent child process by tailing its stream file and monitoring OS PID liveness.
  """
  use GenServer, restart: :temporary

  import Ecto.Query

  alias Rail.Pipeline
  alias Rail.Repo
  alias Rail.Runs
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
    os_process = Keyword.fetch!(opts, :os_process)

    name =
      case opts[:name] do
        custom_name when is_tuple(custom_name) or (is_atom(custom_name) and custom_name not in [nil, false]) ->
          custom_name

        _fallback ->
          {:via, Registry, {FollowerRegistry, os_process.id}}
      end

    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Stops a running process and its follower.
  """
  def stop_os_process(run_or_id, opts \\ [])

  def stop_os_process(%OsProcess{} = os_process, opts) do
    do_stop_os_process(os_process, opts)
  end

  def stop_os_process(id, opts) when is_binary(id) do
    os_process =
      Repo.get(OsProcess, id) ||
        Repo.one(
          from r in OsProcess,
            where: (r.run_id == ^id or r.task_id == ^id) and r.status in [:starting, :running],
            order_by: [desc: r.inserted_at],
            limit: 1
        )

    if os_process do
      do_stop_os_process(os_process, opts)
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
    os_process = Keyword.fetch!(opts, :os_process)
    run = Keyword.get(opts, :run) || Repo.get!(Run, os_process.run_id)
    stream_path = Keyword.get(opts, :stream_path) || os_process.stream_path
    backend = Keyword.fetch!(opts, :backend)
    tail_interval_ms = Keyword.get(opts, :tail_interval_ms, @default_tail_interval)
    batch_interval_ms = Keyword.get(opts, :batch_interval_ms, @default_batch_interval)
    skip_log_lines = Keyword.get(opts, :skip_log_lines, 0)
    file_offset = Keyword.get(opts, :file_offset, 0)

    event_state =
      Runs.new_event_state(backend,
        task_id: os_process.task_id,
        role_id: run.role_id,
        conversation_id: run.conversation_id
      )

    next_seq = Keyword.get(opts, :next_seq, 1)

    state = %__MODULE__{
      os_process_id: os_process.id,
      run_id: run.id,
      task_id: os_process.task_id,
      stream_path: stream_path,
      err_path: "#{stream_path}.err",
      os_pid: Keyword.get(opts, :os_pid) || os_process.os_pid,
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
  def handle_call({:stop_os_process, opts}, _from, state) do
    if is_integer(state.os_pid) and state.os_pid > 0 do
      Tools.terminate_os_process(state.os_pid, opts)
    end

    state = %{state | exit_code: -1}
    {updated_os_process, final_state} = do_child_exit(state)
    {:stop, :normal, {:ok, updated_os_process}, final_state}
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

    register_new_questions(
      updated_state,
      state.event_state.detected_questions,
      updated_state.event_state.detected_questions
    )

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
      flush_pending_events(state.pending_events, state.run_id)
      %{state | pending_events: []}
    end
  end

  defp flush_pending_events([], _run_id), do: []

  defp flush_pending_events(pending_events, run_id) do
    now = DateTime.utc_now()

    entries =
      pending_events
      |> Enum.reverse()
      |> Enum.map(fn {seq, line} ->
        %{
          id: UXID.generate!(),
          run_id: run_id,
          seq: seq,
          line: line,
          inserted_at: now,
          updated_at: now
        }
      end)

    Repo.insert_all(RunEvent, entries)
    Phoenix.PubSub.broadcast(Rail.PubSub, "run:#{run_id}", {:run_events, run_id, entries})
    entries
  end

  defp do_stop_os_process(os_process, opts) do
    case Registry.lookup(FollowerRegistry, os_process.id) do
      [{pid, _registry_val}] ->
        try do
          GenServer.call(pid, {:stop_os_process, opts}, 10_000)
          # coveralls-ignore-start (fallback if follower crashes during stop_os_process)
        catch
          :exit, _reason ->
            fallback_stop_os_process(os_process, opts)
            # coveralls-ignore-stop
        end

      [] ->
        fallback_stop_os_process(os_process, opts)
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
    flush_pending_events(pending_events, state.run_id)

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

    case Repo.get(OsProcess, state.os_process_id) do
      %OsProcess{} = os_process ->
        if state.task_id && event_state.detected_questions != [] && os_process.kind != :chat do
          Pipeline.register_questions(
            state.task_id,
            state.run_id,
            event_state.detected_questions
          )
        end

        {:ok, updated_os_process} =
          os_process
          |> OsProcess.changeset(%{status: :finished})
          |> Repo.update()

        updated_run = update_run(state.run_id, exit_code, error, event_state, os_process.kind)
        outcome = build_outcome(exit_code, error, event_state, updated_os_process, updated_run)

        # Every stage run settles the same way before anything stage-specific is
        # told about it; `on_finished` is only asked where a clean run goes next.
        if os_process.kind != :chat, do: Pipeline.settle_run(updated_os_process, outcome)

        notify_os_process_finished(state.on_finished, updated_os_process, outcome)

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

  # coveralls-ignore-stop

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

  defp update_run(run_id, exit_code, error, event_state, kind) do
    case Repo.get(Run, run_id) do
      %Run{} = run ->
        run_attrs =
          if kind == :chat do
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

  defp notify_os_process_finished(on_finished, updated_os_process, outcome) do
    if is_function(on_finished, 2) do
      on_finished.(updated_os_process, outcome)
    else
      Runs.on_os_process_finished(updated_os_process, outcome)
    end
  end

  # Questions register as soon as they stream in, so the human sees them without
  # waiting for the agent to exit. Only the ones this pump newly saw are sent.
  defp register_new_questions(%{task_id: task_id} = state, before, current) when is_binary(task_id) do
    seen = MapSet.new(before, & &1.prompt)

    case Enum.reject(current, &MapSet.member?(seen, &1.prompt)) do
      [] -> :ok
      new_questions -> Pipeline.register_questions(task_id, state.run_id, new_questions)
    end
  end

  defp register_new_questions(_state, _before, _current), do: :ok
end
