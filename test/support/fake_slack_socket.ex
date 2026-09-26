defmodule Rail.FakeSlackSocket do
  @moduledoc """
  The websocket half of `Rail.FakeSlack`. It says hello the way Slack does, then
  sends whatever the test hands it with `{:push, frame}`, and forwards every
  frame it receives to the test as `{:fake_slack_frame, socket, frame}`.
  """
  @behaviour WebSock

  @impl true
  def init(%{test: test} = state) do
    send(test, {:fake_slack_connected, self()})
    {:push, {:text, Jason.encode!(%{type: "hello", num_connections: 1})}, state}
  end

  @impl true
  def handle_in({text, opcode: :text}, %{test: test} = state) do
    send(test, {:fake_slack_frame, self(), Jason.decode!(text)})
    {:ok, state}
  end

  @impl true
  def handle_info({:push, frame}, state), do: {:push, frame, state}
  def handle_info(:close, state), do: {:stop, :normal, state}

  @impl true
  def terminate(_reason, state), do: {:ok, state}
end
