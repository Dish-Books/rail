defmodule RailTest.RunnerHelpers do
  @moduledoc """
  Plays a sandbox's runner against `Rail.Tools.RunnerSocket`, calling its callbacks in the test process, which then
  stands for the connection, and reads back what it would have sent.
  """

  alias Rail.Tools.RunnerSocket

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
end
