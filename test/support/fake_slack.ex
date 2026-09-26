defmodule Rail.FakeSlack do
  @moduledoc """
  A server that answers like Slack's Socket Mode endpoint, for testing the
  connection without Slack.

  It is a plug whose only job is to upgrade the request to
  `Rail.FakeSlackSocket`, which tells the test process about every connection
  and every frame it receives.
  """
  @behaviour Plug

  @doc """
  Starts the server on a free port, reporting to `test`, and returns the
  websocket URL `apps.connections.open` should hand out.
  """
  def fake_slack(test) when is_pid(test) do
    {:ok, server} = Bandit.start_link(plug: {__MODULE__, test}, port: 0, startup_log: false, ip: :loopback)
    {:ok, {_address, port}} = ThousandIsland.listener_info(server)

    %{url: "ws://127.0.0.1:#{port}/link/?ticket=fake", server: server}
  end

  @impl true
  def init(test), do: test

  @impl true
  def call(conn, test) do
    WebSockAdapter.upgrade(conn, Rail.FakeSlackSocket, %{test: test}, [])
  end
end
