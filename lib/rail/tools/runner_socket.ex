defmodule Rail.Tools.RunnerSocket do
  @moduledoc """
  One sandbox's runner, connected: the WebSocket at `/sandbox/socket` it dials (`RailWeb.SandboxSocketController`
  upgrades to it), and everything between it and Rail. The wire protocol is docs/sandbox-socket.md.

  It checks the task out first on every connection, and only then hands each process's output to its Follower, starts
  what is waiting, and answers calls. A `git` channel is bridged to `git upload-pack` or `git receive-pack` on the
  task's repo, whose pushes it reads before receive-pack does.
  """
  @behaviour WebSock

  import Ecto.Query

  alias Rail.Git
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Tools.RunnerRegistry
  alias Rail.Tools.SandboxProxy
  alias Rail.Tools.Schemas.OsProcess
  alias Rail.Tools.Schemas.Sandbox

  require Logger

  @window 1_048_576
  @ping_ms 20_000
  @max_payload 65_536
  @call_timeout_ms to_timeout(minute: 5)
  @services ["git-upload-pack", "git-receive-pack"]
  @http_kinds ["claude", "mcp"]
  @max_request_body 64 * 1_048_576
  @signals %{"TERM" => 143, "KILL" => 137, "INT" => 130, "HUP" => 129}

  defstruct [
    :sandbox_id,
    :task_id,
    :runner,
    ready?: false,
    failed: nil,
    known: MapSet.new(),
    next_ch: 1,
    next_call: 1,
    procs: %{},
    chans: %{},
    calls: %{},
    http_pids: %{},
    waiting: []
  ]

  @doc """
  The connection for sandbox `sandbox_id`, or nil while its runner is not connected.
  """
  def whereis(sandbox_id) do
    case Registry.lookup(RunnerRegistry, sandbox_id) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end

  @doc """
  Hands process `id`'s output to `follower`: from `out` and `err` when the runner holds the process, else by starting
  it from `exec`, a decoded `exec` message without its `t`, `id` and `ch`. With no `exec` and nothing held, the
  follower is told `{:runner_lost, id}`.
  """
  def follow(conn, id, follower, out, err, exec) when is_pid(conn) do
    send(conn, {:follow, follower, id, out, err, exec})
    :ok
  end

  @doc "Says everything before `offset` of process `id`'s `stream` is safe with Rail."
  def ack(conn, id, stream, offset) when is_pid(conn), do: send(conn, {:ack_proc, id, stream, offset})

  @doc "Says process `id` is settled, so the runner may let its spool go."
  def done(conn, id) when is_pid(conn), do: send(conn, {:done, id})

  @doc "Signals process `id`'s group in sandbox `sandbox_id`, when its runner is connected."
  def signal(sandbox_id, id, signal) when signal in ["TERM", "KILL"] do
    case whereis(sandbox_id) do
      pid when is_pid(pid) -> send(pid, {:signal, id, signal})
      nil -> :ok
    end

    :ok
  end

  @doc """
  Calls `method` on sandbox `sandbox_id`'s runner and waits for its reply. Returns `{:ok, result}`, `{:error, error}`
  as the runner said it, `{:error, :not_running}` when no runner is connected and ready, or `{:error, :timeout}`.
  """
  def call(sandbox_id, method, params, timeout \\ @call_timeout_ms) do
    with pid when is_pid(pid) <- whereis(sandbox_id) || {:error, :not_running} do
      ref = Process.monitor(pid)
      send(pid, {:call, self(), ref, method, params})

      receive do
        {^ref, result} ->
          Process.demonitor(ref, [:flush])
          result

        {:DOWN, ^ref, :process, _pid, _reason} ->
          {:error, :not_running}
      after
        timeout ->
          Process.demonitor(ref, [:flush])
          {:error, :timeout}
      end
    end
  end

  @doc """
  The state of a connection whose request carried `headers` (lowercase names, as Plug has them), or `:error` when they
  name no sandbox that may connect: its token must be one a live sandbox was started with.
  """
  def connect(headers) when is_list(headers) do
    with {_name, token} <- List.keyfind(headers, "x-rail-sandbox-token", 0),
         %Sandbox{} = sandbox <-
           Repo.one(
             from s in Sandbox,
               where: s.token_hash == ^:crypto.hash(:sha256, token) and s.status in [:starting, :running]
           ) do
      runner = with {_name, version} <- List.keyfind(headers, "x-rail-runner", 0), do: version
      {:ok, %__MODULE__{sandbox_id: sandbox.id, task_id: sandbox.task_id, runner: runner}}
    else
      _unknown -> :error
    end
  end

  # A runner that reconnects before its last socket noticed it was gone takes the name over.
  @impl true
  def init(%__MODULE__{sandbox_id: sandbox_id} = state) do
    case Registry.register(RunnerRegistry, sandbox_id, nil) do
      {:ok, _owner} ->
        {:ok, state}

      {:error, {:already_registered, old}} ->
        ref = Process.monitor(old)
        Process.exit(old, :kill)

        receive do
          {:DOWN, ^ref, :process, ^old, _reason} -> init(state)
        end
    end
  end

  @impl true
  def handle_in({text, opcode: :text}, state), do: text |> Jason.decode!() |> message(state)

  def handle_in({<<ch::32, stream::8, offset::64, payload::binary>>, opcode: :binary}, state) do
    data(Map.get(state.chans, ch), ch, stream, offset, payload, state)
  end

  @impl true
  def handle_control(_ping_or_pong, state), do: {:ok, state}

  @impl true
  def handle_info({:follow, follower, id, out, err, exec}, %__MODULE__{ready?: false, failed: nil} = state) do
    {:ok, %{state | waiting: [{follower, id, out, err, exec} | state.waiting]}}
  end

  def handle_info({:follow, follower, id, _out, _err, _exec}, %__MODULE__{ready?: false} = state) do
    send(follower, {:runner_failed, id, state.failed})
    {:ok, state}
  end

  def handle_info({:follow, follower, id, out, err, exec}, state) do
    {frames, state} = attach(state, follower, id, out, err, exec)
    {:push, frames, state}
  end

  def handle_info({:ack_proc, id, stream, offset}, state) do
    case state.procs do
      %{^id => %{ch: ch}} -> {:push, [json(%{t: "ack", ch: ch, stream: stream, offset: offset})], state}
      _detached -> {:ok, state}
    end
  end

  def handle_info({:done, id}, state) do
    {:push, [json(%{t: "done", id: id})], forget(state, id)}
  end

  def handle_info({:signal, id, signal}, state), do: {:push, [json(%{t: "signal", id: id, signal: signal})], state}

  def handle_info({:call, from, ref, _method, _params}, %__MODULE__{ready?: false} = state) do
    send(from, {ref, {:error, :not_running}})
    {:ok, state}
  end

  def handle_info({:call, from, ref, method, params}, state) do
    {frame, state} = start_call(state, {from, ref}, method, params)
    {:push, [frame], state}
  end

  def handle_info({:signed, id, result}, state) do
    reply =
      case result do
        {:ok, signature} -> %{t: "signed", id: id, signature: signature}
        {:error, error} -> %{t: "signed", id: id, error: to_string(error)}
      end

    {:push, [json(reply)], state}
  end

  def handle_info({port, {:data, bytes}}, state) when is_port(port) do
    case Enum.find(state.chans, fn {_ch, chan} -> match?(%{port: ^port}, chan) end) do
      {ch, chan} -> chan |> Map.update!(:queue, &(&1 <> bytes)) |> drain(ch, state)
      nil -> {:ok, state}
    end
  end

  def handle_info({port, {:exit_status, code}}, state) when is_port(port) do
    case Enum.find(state.chans, fn {_ch, chan} -> match?(%{port: ^port}, chan) end) do
      {ch, chan} -> drain(%{chan | exit: code}, ch, state)
      nil -> {:ok, state}
    end
  end

  def handle_info({:http_head, ch, status, headers}, state) do
    case state.chans do
      %{^ch => %{http: _kind}} -> {:push, [json(%{t: "head", ch: ch, status: status, headers: Map.new(headers)})], state}
      _gone -> {:ok, state}
    end
  end

  def handle_info({:http_body, ch, bytes}, state) do
    case state.chans do
      %{^ch => %{http: _kind} = chan} -> chan |> Map.update!(:queue, &(&1 <> bytes)) |> drain(ch, state)
      _gone -> {:ok, state}
    end
  end

  def handle_info({:http_end, ch}, state) do
    case state.chans do
      %{^ch => %{http: _kind} = chan} -> drain(%{chan | exit: :ok}, ch, state)
      _gone -> {:ok, state}
    end
  end

  # A request's process that died before answering ends its channel, so the runner's caller is not left waiting.
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) when is_map_key(state.http_pids, pid) do
    {ch, http_pids} = Map.pop(state.http_pids, pid)
    state = %{state | http_pids: http_pids}

    case state.chans do
      %{^ch => %{exit: nil}} when reason != :normal ->
        close = json(%{t: "close", ch: ch, error: "Rail failed answering the request"})
        {:push, [close], %{state | chans: Map.delete(state.chans, ch)}}

      _answered ->
        {:ok, state}
    end
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    detached =
      for {id, %{pid: ^pid}} <- state.procs, reduce: state do
        acc -> %{acc | procs: Map.delete(acc.procs, id), chans: Map.delete(acc.chans, acc.procs[id].ch)}
      end

    {:ok, detached}
  end

  def handle_info(_other, state), do: {:ok, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.procs, fn {id, %{pid: pid}} -> send(pid, {:runner_down, id}) end)
    for {_ch, %{port: port}} <- state.chans, do: close_port(port)
    for {pid, _ch} <- state.http_pids, do: Process.exit(pid, :kill)
    :ok
  end

  # The checkout comes before anything else: no process starts, and nothing is resumed, in a tree that is not there.
  defp message(%{"t" => "hello", "procs" => procs}, state) do
    now = DateTime.utc_now()
    sandbox = Repo.get!(Sandbox, state.sandbox_id)
    sandbox |> Sandbox.changeset(%{connected_at: now, runner_version: state.runner}) |> Repo.update!()
    %Task{} = task = Repo.preload(Repo.get!(Task, state.task_id), :project)
    held = Map.new(procs, &{&1["id"], &1})

    state = %{state | ready?: false, known: held |> Map.keys() |> MapSet.new(), procs: %{}, chans: %{}}
    welcome = json(%{t: "welcome", window: @window, ping_ms: @ping_ms})

    case Git.checkout_params(task.project, task) do
      {:ok, params} ->
        {call, state} = start_call(state, {:checkout, held}, "checkout", params)
        {:push, [welcome, call], state}

      {:error, reason} ->
        {:ok, state} = replied({:checkout, held}, {:error, reason}, state)
        {:push, [welcome], state}
    end
  end

  defp message(%{"t" => "reply", "id" => id} = reply, state) do
    {waiter, calls} = Map.pop(state.calls, id)
    result = if reply["ok"], do: {:ok, reply["result"]}, else: {:error, reply["error"]}
    replied(waiter, result, %{state | calls: calls})
  end

  defp message(%{"t" => "started", "id" => id, "pid" => pid}, state) do
    case state.procs do
      %{^id => %{pid: follower}} -> send(follower, {:runner_started, id, pid})
      _unfollowed -> :ok
    end

    {:ok, state}
  end

  defp message(%{"t" => "exit", "id" => id} = exit, state) do
    info = %{
      code: exit_code(exit),
      oom: exit["oom"] == true,
      out: exit["out"],
      err: exit["err"]
    }

    case state.procs do
      %{^id => %{pid: pid}} ->
        send(pid, {:runner_exit, id, info})
        {:ok, state}

      # Its Follower is gone: settled already, or Rail restarted and Boot has yet to follow it again.
      _unfollowed ->
        if settled?(id), do: {:push, [json(%{t: "done", id: id})], forget(state, id)}, else: {:ok, state}
    end
  end

  defp message(%{"t" => "sign", "id" => id, "payload" => payload}, state) do
    conn = self()
    task = Repo.get!(Task, state.task_id)

    Elixir.Task.start(fn ->
      result =
        case Base.decode64(payload) do
          {:ok, bytes} -> Git.sign_commit(task, bytes)
          :error -> {:error, "the payload is not base64"}
        end

      send(conn, {:signed, id, result})
    end)

    {:ok, state}
  end

  defp message(%{"t" => "open", "ch" => ch, "kind" => "git", "service" => service}, state) when service in @services do
    %Task{} = task = Repo.get!(Task, state.task_id)
    {executable, args, env} = Git.git_service(task, service)
    # The environment is the whole of it: whatever of Rail's own it leaves out is unset, not inherited.
    unset = for {key, _value} <- System.get_env(), not Map.has_key?(env, key), do: {String.to_charlist(key), false}

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stream,
        cd: Task.repo_path(task),
        args: args,
        env: Enum.map(env, fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end) ++ unset
      ])

    chan = %{
      port: port,
      task: task,
      service: service,
      commands: if(service == "git-receive-pack", do: ""),
      queue: "",
      sent: 0,
      acked: 0,
      exit: nil
    }

    {:ok, %{state | chans: Map.put(state.chans, ch, chan)}}
  end

  # An HTTP request's body is held until its eof, then answered by a process of its own.
  defp message(%{"t" => "open", "ch" => ch, "kind" => kind, "method" => method, "path" => path} = open, state)
       when kind in @http_kinds and is_binary(method) and is_binary(path) do
    chan = %{http: kind, open: open, body: [], size: 0, queue: "", sent: 0, acked: 0, exit: nil}
    {:ok, put_chan(state, ch, chan)}
  end

  defp message(%{"t" => "open", "ch" => ch}, state) do
    {:push, [json(%{t: "close", ch: ch, error: "unsupported"})], state}
  end

  defp message(%{"t" => "eof", "ch" => ch, "stream" => 0}, state) do
    case state.chans do
      %{^ch => %{http: kind, body: body} = chan} when is_list(body) ->
        conn = self()
        sandbox_id = state.sandbox_id
        bytes = body |> Enum.reverse() |> IO.iodata_to_binary()
        open = chan.open
        # As Task would, so whatever owns this socket's database connection and stubs owns the request's too.
        callers = [conn | Process.get(:"$callers", [])]

        {pid, _ref} =
          spawn_monitor(fn ->
            Process.put(:"$callers", callers)

            case kind do
              "claude" -> SandboxProxy.claude(conn, ch, sandbox_id, open, bytes)
              "mcp" -> SandboxProxy.mcp(conn, ch, sandbox_id, open, bytes)
            end
          end)

        state = %{state | http_pids: Map.put(state.http_pids, pid, ch)}
        {:ok, put_chan(state, ch, %{chan | body: nil, open: nil})}

      _other ->
        {:ok, state}
    end
  end

  defp message(%{"t" => "ack", "ch" => ch, "stream" => 0, "offset" => offset}, state) do
    case state.chans do
      %{^ch => %{acked: acked} = chan} -> drain(%{chan | acked: max(acked, offset)}, ch, state)
      _gone -> {:ok, state}
    end
  end

  defp message(%{"t" => "close", "ch" => ch}, state) do
    case Map.pop(state.chans, ch) do
      {%{port: port}, chans} ->
        close_port(port)
        {:ok, %{state | chans: chans}}

      {%{http: _kind}, chans} ->
        {stopped, http_pids} = Map.split_with(state.http_pids, fn {_pid, of} -> of == ch end)
        for {pid, _ch} <- stopped, do: Process.exit(pid, :kill)
        {:ok, %{state | chans: chans, http_pids: http_pids}}

      {_proc_or_nothing, _chans} ->
        {:ok, state}
    end
  end

  # An `eof` needs nothing: git's protocol says when a request is over, so a git channel's input never has to close.
  defp message(%{"t" => _other}, state), do: {:ok, state}

  # A channel and its process are let go together, so a process channel always has its Follower.
  defp data({:proc, id}, _ch, stream, offset, payload, state) do
    %{pid: pid} = Map.fetch!(state.procs, id)
    send(pid, {:runner_data, id, stream, offset, payload})
    {:ok, state}
  end

  # receive-pack is shown a push only once Rail has read which refs it updates and allowed them.
  defp data(%{port: port, commands: buffer} = chan, ch, 0, offset, payload, state) when is_binary(buffer) do
    ack = json(%{t: "ack", ch: ch, stream: 0, offset: offset + byte_size(payload)})

    case push_commands(buffer <> payload) do
      :more ->
        {:push, [ack], put_chan(state, ch, %{chan | commands: buffer <> payload})}

      {:ok, updates, bytes} ->
        case Git.check_push_refs(chan.task, updates) do
          :ok ->
            Port.command(port, bytes)
            {:push, [ack], put_chan(state, ch, %{chan | commands: nil})}

          {:error, ref} ->
            close_port(port)
            error = "Rail takes pushes to its branch, refs/rail/wip and CI receipts only, not #{ref}."
            {:push, [json(%{t: "close", ch: ch, error: error})], %{state | chans: Map.delete(state.chans, ch)}}
        end
    end
  end

  defp data(%{port: port}, ch, 0, offset, payload, state) do
    Port.command(port, payload)
    {:push, [json(%{t: "ack", ch: ch, stream: 0, offset: offset + byte_size(payload)})], state}
  end

  defp data(%{http: _kind, body: body, size: size} = chan, ch, 0, offset, payload, state) when is_list(body) do
    if size + byte_size(payload) > @max_request_body do
      close = json(%{t: "close", ch: ch, error: "The request is over #{div(@max_request_body, 1_048_576)} MiB."})
      {:push, [close], %{state | chans: Map.delete(state.chans, ch)}}
    else
      chan = %{chan | body: [payload | body], size: size + byte_size(payload)}
      {:push, [json(%{t: "ack", ch: ch, stream: 0, offset: offset + byte_size(payload)})], put_chan(state, ch, chan)}
    end
  end

  defp data(_unknown, _ch, _stream, _offset, _payload, state), do: {:ok, state}

  defp attach(state, follower, id, out, err, exec) do
    ch = state.next_ch
    Process.monitor(follower)

    state = %{
      state
      | next_ch: ch + 2,
        procs: Map.put(state.procs, id, %{ch: ch, pid: follower}),
        chans: Map.put(state.chans, ch, {:proc, id})
    }

    cond do
      MapSet.member?(state.known, id) ->
        {[json(%{t: "resume", id: id, ch: ch, out: out, err: err})], state}

      is_map(exec) ->
        {[json(Map.merge(exec, %{"t" => "exec", "id" => id, "ch" => ch}))], %{state | known: MapSet.put(state.known, id)}}

      true ->
        send(follower, {:runner_lost, id})
        {[], forget(state, id)}
    end
  end

  defp start_call(state, waiter, method, params) do
    id = "c#{state.next_call}"
    frame = json(%{t: "call", id: id, method: method, params: params})
    {frame, %{state | next_call: state.next_call + 1, calls: Map.put(state.calls, id, waiter)}}
  end

  defp replied({:checkout, held}, {:ok, _result}, state) do
    sandbox = Repo.get!(Sandbox, state.sandbox_id)
    sandbox |> Sandbox.changeset(%{status: :running, ready_at: DateTime.utc_now()}) |> Repo.update!()
    Phoenix.PubSub.broadcast(Rail.PubSub, "sandboxes", :sandboxes_changed)

    live =
      Repo.all(
        from p in OsProcess,
          where: p.sandbox_id == ^state.sandbox_id and p.status in [:starting, :running],
          select: p.id
      )

    # What the runner holds that Rail settled is stopped and let go; every process Rail still follows hears it is back.
    settled = held |> Map.keys() |> Enum.reject(&(&1 in live))

    frames =
      Enum.flat_map(settled, fn id ->
        done = json(%{t: "done", id: id})
        if held[id]["state"] == "running", do: [json(%{t: "signal", id: id, signal: "KILL"}), done], else: [done]
      end)

    Enum.each(live, &notify(state, &1, {:runner_up, self()}))

    state = %{state | ready?: true, failed: nil, known: Enum.reduce(settled, state.known, &MapSet.delete(&2, &1))}

    {frames, state} =
      state.waiting
      |> Enum.reverse()
      |> Enum.reduce({frames, %{state | waiting: []}}, fn {follower, id, out, err, exec}, {acc, st} ->
        {more, st} = attach(st, follower, id, out, err, exec)
        {acc ++ more, st}
      end)

    {:push, frames, state}
  end

  defp replied({:checkout, _held}, {:error, error}, state) do
    Logger.warning("Sandbox #{state.sandbox_id} could not check its task out: #{inspect(error)}")
    message = "Could not check the task out in its sandbox: #{error}"
    Enum.each(state.waiting, fn {follower, id, _out, _err, _exec} -> send(follower, {:runner_failed, id, message}) end)
    {:ok, %{state | failed: message, waiting: []}}
  end

  defp replied({from, ref}, result, state) do
    send(from, {ref, result})
    {:ok, state}
  end

  defp replied(nil, _result, state), do: {:ok, state}

  defp notify(state, id, message) do
    case Registry.lookup(Rail.Tools.FollowerRegistry, id) do
      [{pid, _value}] -> send(pid, message)
      [] -> :ok
    end

    {:ok, state}
  end

  defp forget(state, id) do
    {proc, procs} = Map.pop(state.procs, id)
    chans = if proc, do: Map.delete(state.chans, proc.ch), else: state.chans
    %{state | procs: procs, chans: chans, known: MapSet.delete(state.known, id)}
  end

  defp settled?(id) do
    not Repo.exists?(from p in OsProcess, where: p.id == ^id and p.status in [:starting, :running])
  end

  # A process killed by a signal says so as the shell would: 128 and the signal's number.
  defp exit_code(%{"code" => code, "signal" => signal}) when code == -1 and is_binary(signal),
    do: Map.get(@signals, signal, -1)

  defp exit_code(%{"code" => code}), do: code

  # Sends what a git service or an HTTP answer wrote as far as the runner's window allows, and closes the channel once
  # the service has exited, or the answer ended, and everything it wrote is sent.
  defp drain(chan, ch, state) do
    room = max(@window - (chan.sent - chan.acked), 0)
    size = min(room, byte_size(chan.queue))
    <<sending::binary-size(^size), rest::binary>> = chan.queue
    frames = chunks(ch, chan.sent, sending)
    chan = %{chan | queue: rest, sent: chan.sent + size}

    if chan.exit != nil and rest == "" do
      close = json(if(chan.exit == :ok, do: %{t: "close", ch: ch}, else: %{t: "close", ch: ch, code: chan.exit}))
      {:push, Enum.reverse([close | Enum.reverse(frames)]), %{state | chans: Map.delete(state.chans, ch)}}
    else
      {:push, frames, put_chan(state, ch, chan)}
    end
  end

  defp chunks(_ch, _offset, ""), do: []

  defp chunks(ch, offset, bytes) do
    size = min(byte_size(bytes), @max_payload)
    <<payload::binary-size(^size), rest::binary>> = bytes
    [{:binary, <<ch::32, 0::8, offset::64, payload::binary>>} | chunks(ch, offset + size, rest)]
  end

  defp put_chan(state, ch, chan), do: %{state | chans: Map.put(state.chans, ch, chan)}

  # A push's commands are pkt-lines up to a flush: `<old> <new> <ref>`, the first with capabilities after a NUL, after
  # any `shallow` lines. Returns the updates and everything read so far, or `:more` until the flush has come.
  defp push_commands(bytes), do: push_commands(bytes, bytes, [])

  defp push_commands(<<"0000", _rest::binary>>, all, updates), do: {:ok, Enum.reverse(updates), all}

  defp push_commands(<<hex::binary-size(4), rest::binary>>, all, updates) do
    with {length, ""} when length > 4 <- Integer.parse(hex, 16),
         body = length - 4,
         <<line::binary-size(^body), more::binary>> <- rest do
      case line |> String.split("\0") |> hd() |> String.trim_trailing("\n") |> String.split(" ") do
        ["shallow", _oid] -> push_commands(more, all, updates)
        [old, new, ref] -> push_commands(more, all, [{old, new, ref} | updates])
        _other -> {:ok, [{"", "", "a malformed command"}], all}
      end
    else
      :error -> {:ok, [{"", "", "a malformed command"}], all}
      {_length, _rest} -> {:ok, [{"", "", "a malformed command"}], all}
      _short -> :more
    end
  end

  defp push_commands(_partial, _all, _updates), do: :more

  defp close_port(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp json(map), do: {:text, Jason.encode!(map)}
end
