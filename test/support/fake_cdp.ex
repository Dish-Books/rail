defmodule Rail.FakeCdp do
  @moduledoc """
  A server that answers like Chrome's DevTools endpoint, for testing the browser
  connection without a browser.

  It is a plug whose only job is to upgrade the request to
  `Rail.FakeCdpSocket`, which is where the answering happens.
  """
  @behaviour Plug

  @doc """
  Starts the server on a free port and returns the websocket URL to connect to.
  """
  def fake_cdp do
    {:ok, server} = Bandit.start_link(plug: __MODULE__, port: 0, startup_log: false, ip: :loopback)
    {:ok, {_address, port}} = ThousandIsland.listener_info(server)

    %{url: "ws://127.0.0.1:#{port}/devtools/browser/fake", server: server}
  end

  @impl true
  def init(options), do: options

  @impl true
  def call(conn, _options) do
    WebSockAdapter.upgrade(conn, Rail.FakeCdpSocket, %{}, [])
  end
end
