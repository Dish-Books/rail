defmodule Rail.FakeCdpSocket do
  @moduledoc """
  The websocket half of `Rail.FakeCdp`: answers a frame the way Chrome's DevTools
  endpoint does.

  Every frame comes back as a result echoing exactly what arrived, so a test can
  assert on the shape Rail put on the wire rather than on what it meant to. The
  `Test.*` methods are the ones that behave badly on purpose: answering with an
  error, answering late, talking unprompted, and each of the malformed or
  unexpected things a real socket can put on the wire.
  """
  @behaviour WebSock

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_in({text, opcode: :text}, state) do
    %{"id" => id, "method" => method} = frame = Jason.decode!(text)
    result = %{"echo" => Map.get(frame, "params"), "session" => Map.get(frame, "sessionId")}

    case method do
      "Test.Error" ->
        {:push, {:text, Jason.encode!(%{id: id, error: %{message: "no such target"}})}, state}

      "Test.Slow" ->
        Process.send_after(self(), {:answer, id, result}, 80)
        {:ok, state}

      "Test.Event" ->
        event = Jason.encode!(%{method: "Page.screencastFrame", params: %{"data" => "frame"}})
        {:push, [{:text, event}, {:text, Jason.encode!(%{id: id, result: result})}], state}

      # Everything a socket can carry that is not an answer: text that is not
      # JSON, JSON that is neither a reply nor an event, a reply that says
      # nothing, a frame that is not text at all, and the close.
      "Test.Noise" ->
        {:push,
         [
           {:text, "}not json{"},
           {:text, Jason.encode!(%{hello: "there"})},
           {:text, Jason.encode!(%{id: 9_999, result: result})},
           {:binary, <<1, 2, 3>>},
           {:text, Jason.encode!(%{id: id})}
         ], state}

      "Test.Close" ->
        {:push, [{:text, Jason.encode!(%{id: id, result: result})}, :close], state}

      _ordinary ->
        {:push, {:text, Jason.encode!(%{id: id, result: result})}, state}
    end
  end

  @impl true
  def handle_info({:answer, id, result}, state) do
    {:push, {:text, Jason.encode!(%{id: id, result: result})}, state}
  end

  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def terminate(_reason, state), do: {:ok, state}
end
