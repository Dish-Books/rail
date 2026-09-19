defmodule Rail.Tools.BrowserTest do
  use ExUnit.Case, async: true

  import Rail.FakeCdp

  alias Rail.Tools.Browser

  setup do
    %{url: url} = fake_cdp()

    %{url: url}
  end

  # The upgrade takes a round trip, and a caller that does not know that sends its
  # first command straight away. A connection that read its own mailbox while
  # upgrading swallowed that call and the caller waited for a reply to a command
  # that was never sent.
  test "answers a command sent before the upgrade has finished", %{url: url} do
    {:ok, connection} = Browser.start_link(url: url)

    assert {:ok, %{"echo" => %{"url" => "about:blank"}}} =
             Browser.call(connection, "Target.createTarget", %{url: "about:blank"}, 5_000)
  end

  # Chrome refuses a frame carrying any key beyond these four, so what goes on the
  # wire is asserted rather than what it was meant to be.
  test "puts the method's arguments under params and the session at the top", %{url: url} do
    {:ok, connection} = Browser.start_link(url: url)

    echo = %{"expression" => "1 + 1", "returnByValue" => true}

    assert {:ok, %{"echo" => ^echo, "session" => "sess_1"}} =
             Browser.call(connection, "Runtime.evaluate", %{
               expression: "1 + 1",
               returnByValue: true,
               session: "sess_1"
             })
  end

  test "a command that takes nothing still sends an empty params", %{url: url} do
    {:ok, connection} = Browser.start_link(url: url)

    assert {:ok, %{"echo" => %{}, "session" => nil}} = Browser.call(connection, "Browser.getVersion")
  end

  # Acknowledging a screencast frame addresses the tab and names the frame, and
  # both of those are spelt `sessionId` in Chrome's own protocol. The one that
  # routes is the one Rail calls `:session`.
  test "a method whose own arguments include a session id still reaches its tab", %{url: url} do
    {:ok, connection} = Browser.start_link(url: url)

    assert {:ok, %{"echo" => %{"sessionId" => 7}, "session" => "sess_1"}} =
             Browser.call(connection, "Page.screencastFrameAck", %{session: "sess_1", sessionId: 7})
  end

  # Acknowledging a frame happens many times a second and its answer carries
  # nothing, so waiting for one would hold up the next frame for no reason.
  test "a cast reaches Chrome without anybody waiting for the answer", %{url: url} do
    {:ok, connection} = Browser.start_link(url: url)

    assert :ok = Browser.cast(connection, "Page.screencastFrameAck", %{sessionId: 1})

    # The connection is still good, which is the whole of what a cast promises.
    assert {:ok, %{"echo" => %{}}} = Browser.call(connection, "Browser.getVersion")
  end

  # A DevTools URL carries a query in some Chrome builds, and dropping it asks
  # the wrong endpoint for the socket.
  test "a url with a query keeps it", %{url: url} do
    {:ok, connection} = Browser.start_link(url: url <> "?foo=1")

    assert {:ok, %{"echo" => %{}}} = Browser.call(connection, "Browser.getVersion")
  end

  # A long-lived socket carries things that are not answers, and none of them is
  # a reason to take the connection down or to wake a caller with nonsense.
  test "noise on the wire is ignored rather than answered", %{url: url} do
    {:ok, connection} = Browser.start_link(url: url)

    # A reply with no result and no error is still that command's answer.
    assert {:ok, %{}} = Browser.call(connection, "Test.Noise")

    # Anything in this process's own mailbox that is not the socket's.
    send(connection, :tick)

    assert {:ok, %{"echo" => %{}}} = Browser.call(connection, "Browser.getVersion")
  end

  # Chrome exiting closes the socket, and a connection to a browser that is gone
  # would accept commands and time out on every one of them.
  test "the connection ends when the socket does", %{url: url} do
    Process.flag(:trap_exit, true)
    {:ok, connection} = Browser.start_link(url: url)

    assert {:ok, _closing} = Browser.call(connection, "Test.Close")

    assert_receive {:EXIT, ^connection, :normal}, 5_000
  end

  # Chrome answers whenever each command is ready, so a caller waits on its own id
  # rather than on the next frame to arrive.
  test "a slow command does not hold up the one behind it", %{url: url} do
    {:ok, connection} = Browser.start_link(url: url)

    slow = Task.async(fn -> Browser.call(connection, "Test.Slow", %{n: 1}) end)
    Process.sleep(10)

    assert {:ok, %{"echo" => %{"n" => 2}}} = Browser.call(connection, "Test.Fast", %{n: 2})
    assert {:ok, %{"echo" => %{"n" => 1}}} = Task.await(slow)
  end

  # A page that navigated out from under a command is ordinary, so a refusal comes
  # back rather than raising.
  test "a command Chrome refuses comes back as an error", %{url: url} do
    {:ok, connection} = Browser.start_link(url: url)

    assert {:error, "no such target"} = Browser.call(connection, "Test.Error")
  end

  test "what Chrome says unprompted goes to the subscribers", %{url: url} do
    {:ok, connection} = Browser.start_link(url: url, subscribe: self())

    assert {:ok, _result} = Browser.call(connection, "Test.Event")
    assert_receive {:cdp_event, "Page.screencastFrame", %{"data" => "frame"}}
  end

  test "a process can subscribe after the connection is up", %{url: url} do
    {:ok, connection} = Browser.start_link(url: url)

    assert :ok = Browser.subscribe(connection, self())
    assert {:ok, _result} = Browser.call(connection, "Test.Event")
    assert_receive {:cdp_event, "Page.screencastFrame", _params}
  end

  # The connect happens after the process is up, so a browser that is not there
  # takes the connection down rather than failing the start. Whatever is
  # supervising it hears that, which is what tells the session its browser is gone.
  test "a connection to nothing goes down saying why" do
    Process.flag(:trap_exit, true)

    assert {:ok, connection} = Browser.start_link(url: "ws://127.0.0.1:1/devtools/browser/gone")
    reference = Process.monitor(connection)

    assert_receive {:DOWN, ^reference, :process, ^connection, {:cdp_connect_failed, _reason}}, 5_000
  end
end
