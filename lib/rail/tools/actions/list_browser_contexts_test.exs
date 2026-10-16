defmodule Rail.Tools.Actions.ListBrowserContextsTest do
  use Rail.DataCase, async: false

  import Rail.Tools.Utils.EnsureBrowserHost

  alias Rail.Tools
  alias Rail.Tools.Browser

  # Serial, and against a real Chrome: what is under test is what Chrome says it holds.
  @moduletag :browser

  setup_all do
    {:ok, _host} = ensure_browser_host(ready_timeout_ms: 60_000)
    :ok
  end

  test "lists the contexts Chrome holds, and not one it has closed" do
    {:ok, %{url: url}} = ensure_browser_host(start: false)
    {:ok, connection} = Browser.start_link(url: url)
    {:ok, %{"browserContextId" => context}} = Browser.call(connection, "Target.createBrowserContext", %{})

    assert {:ok, contexts} = Tools.list_browser_contexts()
    assert MapSet.member?(contexts, context)

    {:ok, _closed} = Browser.call(connection, "Target.disposeBrowserContext", %{browserContextId: context})
    GenServer.stop(connection)

    assert {:ok, contexts} = Tools.list_browser_contexts()
    refute MapSet.member?(contexts, context)
  end

  # Not knowing is not the same as holding nothing: a row settled on a Chrome that
  # was only busy would leave its tab open with nobody to close it.
  test "a Chrome that does not answer is unknown rather than empty" do
    stub(Browser, :start_link, fn _opts -> {:error, :econnrefused} end)

    assert Tools.list_browser_contexts() == :unknown
  end

  test "a Chrome that refuses the question is unknown too" do
    # Chrome answers only once the socket is up, so the refusal waits for it too:
    # stopping a connection still mid-handshake would outlast the stop's timeout.
    stub(Browser, :call, fn connection, "Target.getBrowserContexts", _params ->
      _connected = :sys.get_state(connection)
      {:error, "Not allowed"}
    end)

    assert Tools.list_browser_contexts() == :unknown
  end
end
