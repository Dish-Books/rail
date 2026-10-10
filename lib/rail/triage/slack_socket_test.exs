defmodule Rail.Triage.SlackSocketTest do
  use Rail.DataCase, async: true

  import Rail.FakeSlack

  alias Ecto.Adapters.SQL.Sandbox
  alias Rail.Triage.Schemas.Message
  alias Rail.Triage.SlackSocket

  # Opening a websocket waits on the machine, so a loaded suite gets longer than the default.
  @connect_timeout 15_000

  setup %{project: project} do
    %{workspace: workspace, channel: channel} = connect_slack_channel(project)
    %{url: url} = fake_slack(self())
    test = self()
    # What `conversations.history` answers, which a test changes to post behind the socket's back.
    history = start_supervised!({Agent, fn -> [] end})

    Req.Test.stub(Rail.Slack, fn conn ->
      case conn.request_path do
        # Asked by the socket itself before it does anything else, so here is where it joins the test's sandbox.
        "/api/apps.connections.open" ->
          Sandbox.allow(Repo, test, self())
          Req.Test.allow(Rail.Slack, test, self())
          assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer #{workspace.app_token}"]
          Req.Test.json(conn, %{"ok" => true, "url" => url})

        "/api/users.info" ->
          Req.Test.json(conn, %{"ok" => true, "user" => %{"real_name" => "Priya"}})

        "/api/conversations.history" ->
          send(test, :history_read)
          Req.Test.json(conn, %{"ok" => true, "messages" => Agent.get(history, & &1)})
      end
    end)

    %{workspace: workspace, channel: channel, url: url, history: history}
  end

  test "connects to the URL Slack hands out, acks an event, and files its message", %{
    workspace: workspace,
    channel: channel
  } do
    start_supervised!({SlackSocket, workspace: workspace, backoff: 10})

    assert_receive {:fake_slack_connected, fake}, @connect_timeout

    eventually(fn ->
      assert %{status: :connected, last_frame_at: %DateTime{}} = Rail.Triage.get_slack_socket_status(workspace)
    end)

    envelope = %{
      "envelope_id" => "env-1",
      "type" => "events_api",
      "payload" => slack_message_event(channel, %{"text" => "Checkout is broken"})
    }

    send(fake, {:push, {:text, Jason.encode!(envelope)}})

    assert_receive {:fake_slack_frame, ^fake, %{"envelope_id" => "env-1"}}

    eventually(fn ->
      assert %Message{text: "Checkout is broken", author_name: "Priya"} =
               Repo.get_by(Message, external_id: "1790000000.000100")
    end)
  end

  test "an envelope it has no use for is acked and nothing else", %{workspace: workspace} do
    start_supervised!({SlackSocket, workspace: workspace, backoff: 10})
    assert_receive {:fake_slack_connected, fake}, @connect_timeout

    send(fake, {:push, {:text, "not json"}})
    send(fake, {:push, {:binary, <<1, 2>>}})
    send(fake, {:push, {:ping, "still there?"}})
    send(fake, {:push, {:text, Jason.encode!(%{"type" => "hello"})}})
    send(fake, {:push, {:text, Jason.encode!(%{"envelope_id" => "env-2", "type" => "slash_commands"})}})

    assert_receive {:fake_slack_frame, ^fake, %{"envelope_id" => "env-2"}}
    refute_receive {:fake_slack_frame, ^fake, _other}
  end

  test "a disconnect, or the connection dropping, opens a new one", %{workspace: workspace} do
    start_supervised!({SlackSocket, workspace: workspace, backoff: 10})
    assert_receive {:fake_slack_connected, first}, @connect_timeout

    send(first, {:push, {:text, Jason.encode!(%{"type" => "disconnect", "reason" => "refresh_requested"})}})
    assert_receive {:fake_slack_connected, second}, @connect_timeout
    refute second == first

    send(second, :close)
    assert_receive {:fake_slack_connected, third}, @connect_timeout
    refute third == second

    Process.exit(third, :kill)
    assert_receive {:fake_slack_connected, fourth}, @connect_timeout
    refute fourth == third
  end

  test "a disconnect that lands with the hello, before the upgrade is done, still opens a new one", %{
    workspace: workspace,
    url: url
  } do
    Req.Test.expect(Rail.Slack, &Req.Test.json(&1, %{"ok" => true, "url" => url <> "&greet=disconnect"}))
    start_supervised!({SlackSocket, workspace: workspace, backoff: 10})

    assert_receive {:fake_slack_connected, first}, @connect_timeout
    assert_receive {:fake_slack_connected, second}, @connect_timeout
    refute second == first
  end

  test "keeps trying when Slack will not open a connection, or its URL does not answer", %{workspace: workspace} do
    Req.Test.expect(Rail.Slack, &Req.Test.json(&1, %{"ok" => false, "error" => "invalid_auth"}))
    Req.Test.expect(Rail.Slack, &Req.Test.json(&1, %{"ok" => true, "url" => "ws://127.0.0.1:1/link"}))

    start_supervised!({SlackSocket, workspace: workspace, backoff: 10})

    assert_receive {:fake_slack_connected, _socket}, @connect_timeout
  end

  test "says why while Slack will not open a connection, and that it is off when no socket runs", %{
    workspace: workspace
  } do
    assert %{status: :off, last_frame_at: nil} = Rail.Triage.get_slack_socket_status(workspace)

    test = self()

    Req.Test.stub(Rail.Slack, fn conn ->
      send(test, :refused)
      Req.Test.json(conn, %{"ok" => false, "error" => "not_allowed_token_type"})
    end)

    # Pinging all the while, with no connection to ping.
    start_supervised!({SlackSocket, workspace: workspace, backoff: 10, ping_interval: 5})

    eventually(fn ->
      assert %{status: {:error, {:slack_error, "not_allowed_token_type"}}} =
               Rail.Triage.get_slack_socket_status(workspace)
    end)

    # The retry is ten off and the first ping five, so by the second refusal it has pinged.
    assert_receive :refused, @connect_timeout
    assert_receive :refused, @connect_timeout
  end

  test "a connection that stops answering is reopened, and one that answers its pings is kept", %{workspace: workspace} do
    # Idle for a second, which a pong on a loaded machine does not take; a tenth of one, it did.
    start_supervised!({SlackSocket, workspace: workspace, backoff: 10, ping_interval: 20, idle_timeout: 1_000})
    assert_receive {:fake_slack_connected, first}, @connect_timeout
    refute_receive {:fake_slack_connected, _reopened}, 1_500

    # Suspended, it reads nothing and closes nothing, which is all a dead connection looks like from here.
    :sys.suspend(first)
    assert_receive {:fake_slack_connected, second}, @connect_timeout
    refute second == first
    :sys.resume(first)
  end

  test "the connection Slack is about to close is read until the drain runs out", %{
    workspace: workspace,
    channel: channel
  } do
    start_supervised!({SlackSocket, workspace: workspace, backoff: 10, drain: 1_000})
    assert_receive {:fake_slack_connected, first}, @connect_timeout

    send(first, {:push, {:text, Jason.encode!(%{"type" => "disconnect", "reason" => "refresh_requested"})}})
    assert_receive {:fake_slack_connected, second}, @connect_timeout

    # Both connections are read at once, so each is sent something while the other is open - once
    # the new one's upgrade is done, or it is read with the upgrade rather than alongside the old one.
    eventually(fn -> assert %{status: :connected} = Rail.Triage.get_slack_socket_status(workspace) end)
    send(second, {:push, {:text, Jason.encode!(%{"envelope_id" => "env-new", "type" => "slash_commands"})}})
    assert_receive {:fake_slack_frame, ^second, %{"envelope_id" => "env-new"}}

    envelope = %{
      "envelope_id" => "env-late",
      "type" => "events_api",
      "payload" => slack_message_event(channel, %{"text" => "Sent down the old connection"})
    }

    send(first, {:push, {:text, Jason.encode!(envelope)}})
    assert_receive {:fake_slack_frame, ^first, %{"envelope_id" => "env-late"}}
    eventually(fn -> assert %Message{} = Repo.get_by(Message, text: "Sent down the old connection") end)

    assert_receive {:fake_slack_closed, ^first}, @connect_timeout
  end

  test "every connection files what was posted while there was none", %{workspace: workspace, history: history} do
    ts = :erlang.float_to_binary(System.os_time(:microsecond) / 1_000_000, decimals: 6)
    Agent.update(history, fn _none -> [%{"type" => "message", "user" => "U_PRIYA", "text" => "Missed", "ts" => ts}] end)

    start_supervised!({SlackSocket, workspace: workspace, backoff: 10})
    assert_receive {:fake_slack_connected, _fake}, @connect_timeout

    eventually(fn -> assert %Message{author_name: "Priya"} = Repo.get_by(Message, text: "Missed") end)
  end

  test "a connected socket that delivered nothing of what Slack's history shows files it and reopens", %{
    workspace: workspace,
    history: history
  } do
    start_supervised!({SlackSocket, workspace: workspace, backoff: 10, backfill_interval: 30, delivery_grace: 0})
    assert_receive {:fake_slack_connected, first}, @connect_timeout

    # Posted once the interval has read as well as the backfill the connection opened with, or a
    # slow first read could find it and leave the interval never run.
    assert_receive :history_read, @connect_timeout
    assert_receive :history_read, @connect_timeout

    ts = :erlang.float_to_binary(System.os_time(:microsecond) / 1_000_000, decimals: 6)
    Agent.update(history, fn _none -> [%{"type" => "message", "user" => "U_PRIYA", "text" => "Unheard", "ts" => ts}] end)

    assert_receive {:fake_slack_connected, second}, @connect_timeout
    refute second == first
    assert %Message{} = Repo.get_by(Message, text: "Unheard")
  end
end
