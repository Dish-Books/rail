defmodule Rail.Triage.SlackSocketTest do
  use Rail.DataCase, async: true

  import Rail.FakeSlack

  alias Ecto.Adapters.SQL.Sandbox
  alias Rail.Triage.Schemas.Message
  alias Rail.Triage.SlackSocket

  # Opening a websocket waits on the machine, so a loaded suite gets longer than the default.
  @connect_timeout 5_000

  setup %{project: project} do
    %{workspace: workspace, channel: channel} = connect_slack_channel(project)
    %{url: url} = fake_slack(self())

    Req.Test.stub(Rail.Slack, fn conn ->
      case conn.request_path do
        "/api/apps.connections.open" ->
          assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer #{workspace.app_token}"]
          Req.Test.json(conn, %{"ok" => true, "url" => url})

        "/api/users.info" ->
          Req.Test.json(conn, %{"ok" => true, "user" => %{"real_name" => "Priya"}})
      end
    end)

    %{workspace: workspace, channel: channel}
  end

  test "connects to the URL Slack hands out, acks an event, and files its message", %{
    workspace: workspace,
    channel: channel
  } do
    pid = start_supervised!({SlackSocket, workspace: workspace, backoff: 10})
    Sandbox.allow(Repo, self(), pid)
    Req.Test.allow(Rail.Slack, self(), pid)

    assert_receive {:fake_slack_connected, fake}, @connect_timeout

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

  test "keeps trying when Slack will not open a connection, or its URL does not answer", %{workspace: workspace} do
    Req.Test.expect(Rail.Slack, &Req.Test.json(&1, %{"ok" => false, "error" => "invalid_auth"}))
    Req.Test.expect(Rail.Slack, &Req.Test.json(&1, %{"ok" => true, "url" => "ws://127.0.0.1:1/link"}))

    start_supervised!({SlackSocket, workspace: workspace, backoff: 10})

    assert_receive {:fake_slack_connected, _socket}, @connect_timeout
  end
end
