defmodule RailTest.RunnerHelpers do
  @moduledoc """
  Plays a sandbox's runner against `Rail.Tools.RunnerSocket`, calling its callbacks in the test process, which then
  stands for the connection, and reads back what it would have sent.
  """

  import ExUnit.Assertions

  alias Rail.Tools.RunnerSocket
  alias Rail.Tools.Schemas.Backend

  @doc "Hands the socket a JSON control message from the runner."
  def runner_message(state, message), do: RunnerSocket.handle_in({Jason.encode!(message), opcode: :text}, state)

  @doc "Says hello with the processes the runner holds."
  def runner_hello(state, procs), do: runner_message(state, %{"t" => "hello", "runner" => "1.2.3", "procs" => procs})

  @doc ~s(Replies to call `id`, e.g. `%{"ok" => true, "result" => ...}`.)
  def runner_reply(state, id, reply), do: runner_message(state, Map.merge(reply, %{"t" => "reply", "id" => id}))

  @doc "Registers the test process as the connection, says hello holding `procs`, and has the checkout succeed."
  def runner_ready(state, procs) do
    {:ok, state} = RunnerSocket.init(state)
    {:push, _welcome, state} = runner_hello(state, procs)
    {:push, _frames, state} = runner_reply(state, "c1", %{"ok" => true, "result" => %{}})
    state
  end

  @doc "The control messages among `frames`, decoded."
  def runner_frames(frames), do: for({:text, json} <- frames, do: Jason.decode!(json))

  @doc "A git pkt-line holding `line`."
  def pkt_line(line), do: String.pad_leading(Integer.to_string(byte_size(line) + 4, 16), 4, "0") <> line

  @doc "What `Rail.Tools.SandboxProxy` sent for channel `ch`, up to and including its end."
  def proxy_answer(ch, acc \\ []) do
    receive do
      {:http_end, ^ch} = done -> Enum.reverse([done | acc])
      {:http_head, ^ch, _status, _headers} = message -> proxy_answer(ch, [message | acc])
      {:http_body, ^ch, _bytes} = message -> proxy_answer(ch, [message | acc])
    after
      1_000 -> flunk("no answer on #{ch}: #{inspect(Enum.reverse(acc))}")
    end
  end

  @doc "A request of the turn `proc` to Claude, as the runner opens its channel."
  def claude_open(proc, path, headers), do: %{"proc" => proc, "method" => "POST", "path" => path, "headers" => headers}

  @doc "Gives `backend` a login whose token is `token`, expiring at `expires_at` in ms, or never with nil."
  def claude_login(%Backend{} = backend, token, expires_at) do
    oauth = if expires_at, do: %{"accessToken" => token, "expiresAt" => expires_at}, else: %{"accessToken" => token}
    File.write!(Path.join(Backend.config_dir(backend), ".credentials.json"), Jason.encode!(%{"claudeAiOauth" => oauth}))
  end

  @doc """
  Follows process `id` on a real runner's connection `conn` to its exit, acking as it goes, and returns
  `{stdout, stderr, code}`.
  """
  def follow_to_exit(conn, id, out \\ "", err \\ "") do
    receive do
      {:runner_started, ^id, _pid} ->
        follow_to_exit(conn, id, out, err)

      {:runner_data, ^id, stream, offset, bytes} ->
        RunnerSocket.ack(conn, id, stream, offset + byte_size(bytes))
        if stream == 1, do: follow_to_exit(conn, id, out <> bytes, err), else: follow_to_exit(conn, id, out, err <> bytes)

      {:runner_exit, ^id, %{code: code}} ->
        {out, err, code}
    after
      60_000 -> flunk("no exit\n#{err}\n#{out}")
    end
  end

  @doc "Every `{:upstream, ...}` message the test process holds, oldest first."
  def upstream_requests(acc \\ []) do
    receive do
      {:upstream, method, path, headers, body} -> upstream_requests([{method, path, headers, body} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
