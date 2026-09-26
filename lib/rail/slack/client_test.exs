defmodule Rail.Slack.ClientTest do
  use Rail.DataCase, async: true

  alias Rail.Projects.Schemas.SlackWorkspace
  alias Rail.Slack

  setup do
    %{workspace: %SlackWorkspace{token: "xoxb-bot", app_token: "xapp-app"}}
  end

  test "bot calls go out on the bot token and hand back Slack's body", %{workspace: workspace} do
    Req.Test.expect(Slack, fn conn ->
      assert conn.request_path == "/api/auth.test"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer xoxb-bot"]
      Req.Test.json(conn, %{"ok" => true, "team_id" => "T1", "bot_id" => "B1", "user_id" => "U1"})
    end)

    assert {:ok, %{"team_id" => "T1", "bot_id" => "B1"}} = Slack.auth_test(workspace)
  end

  test "a body Slack marks not ok is an error", %{workspace: workspace} do
    Req.Test.expect(Slack, &Req.Test.json(&1, %{"ok" => false, "error" => "invalid_auth"}))

    assert {:error, {:slack_error, "invalid_auth"}} = Slack.auth_test(workspace)
  end

  test "a failed request is an error", %{workspace: workspace} do
    Req.Test.expect(Slack, &Plug.Conn.send_resp(&1, 500, "down"))

    assert {:error, {:slack_error, 500}} = Slack.auth_test(workspace)
  end

  test "a Slack that cannot be reached is an error", %{workspace: workspace} do
    Req.Test.expect(Slack, &Req.Test.transport_error(&1, :econnrefused))

    assert {:error, %Req.TransportError{reason: :econnrefused}} = Slack.auth_test(workspace)
  end

  test "lists public and private channels across pages", %{workspace: workspace} do
    Req.Test.expect(Slack, fn conn ->
      assert %{"types" => "public_channel,private_channel", "exclude_archived" => "true"} = conn.query_params
      refute conn.query_params["cursor"]

      Req.Test.json(conn, %{
        "ok" => true,
        "channels" => [%{"id" => "C1", "name" => "feedback"}],
        "response_metadata" => %{"next_cursor" => "page2"}
      })
    end)

    Req.Test.expect(Slack, fn conn ->
      assert %{"cursor" => "page2"} = conn.query_params

      Req.Test.json(conn, %{
        "ok" => true,
        "channels" => [%{"id" => "C2", "name" => "billing"}],
        "response_metadata" => %{"next_cursor" => ""}
      })
    end)

    assert {:ok, [%{"id" => "C1"}, %{"id" => "C2"}]} = Slack.list_channels(workspace)
  end

  test "reads a thread's replies, a user and a permalink", %{workspace: workspace} do
    Req.Test.expect(Slack, fn conn ->
      assert conn.request_path == "/api/conversations.replies"
      assert %{"channel" => "C1", "ts" => "1.0"} = conn.query_params
      Req.Test.json(conn, %{"ok" => true, "messages" => [%{"ts" => "1.0"}, %{"ts" => "2.0"}]})
    end)

    Req.Test.expect(Slack, fn conn ->
      assert %{"user" => "U9"} = conn.query_params
      Req.Test.json(conn, %{"ok" => true, "user" => %{"id" => "U9", "real_name" => "Priya"}})
    end)

    Req.Test.expect(Slack, fn conn ->
      assert %{"channel" => "C1", "message_ts" => "1.0"} = conn.query_params
      Req.Test.json(conn, %{"ok" => true, "permalink" => "https://slack.example/p1"})
    end)

    assert {:ok, [%{"ts" => "1.0"}, %{"ts" => "2.0"}]} = Slack.replies(workspace, "C1", "1.0")
    assert {:ok, %{"id" => "U9", "real_name" => "Priya"}} = Slack.user_info(workspace, "U9")
    assert {:ok, "https://slack.example/p1"} = Slack.permalink(workspace, "C1", "1.0")
  end

  test "opens a Socket Mode connection on the app-level token", %{workspace: workspace} do
    Req.Test.expect(Slack, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/api/apps.connections.open"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer xapp-app"]
      Req.Test.json(conn, %{"ok" => true, "url" => "wss://wss.slack.example/link"})
    end)

    assert {:ok, "wss://wss.slack.example/link"} = Slack.open_connection(workspace)
  end

  test "posts in a thread on the token it is given" do
    Req.Test.expect(Slack, fn conn ->
      assert conn.request_path == "/api/chat.postMessage"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer xoxp-person"]

      assert %{"channel" => "C1", "thread_ts" => "1.0", "text" => "Thanks"} =
               conn |> Req.Test.raw_body() |> Jason.decode!()

      Req.Test.json(conn, %{"ok" => true, "ts" => "3.0"})
    end)

    assert {:ok, %{"ts" => "3.0"}} = Slack.post_message("xoxp-person", "C1", "1.0", "Thanks")
  end

  test "asks a person to let Rail post as them" do
    url = Slack.authorize_url(state: "st", team: "T1")

    assert %URI{host: "slack.com", path: "/oauth/v2/authorize", query: query} = URI.parse(url)

    assert %{"user_scope" => "chat:write", "state" => "st", "team" => "T1", "client_id" => "slack_client_id"} =
             URI.decode_query(query)
  end

  test "trades an authorization code for the person's token" do
    Req.Test.expect(Slack, fn conn ->
      assert conn.request_path == "/api/oauth.v2.access"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert %{"code" => "c0de", "client_secret" => "slack_client_secret"} = URI.decode_query(body)
      Req.Test.json(conn, %{"ok" => true, "authed_user" => %{"id" => "U1", "access_token" => "xoxp-1"}})
    end)

    assert {:ok, %{"authed_user" => %{"access_token" => "xoxp-1"}}} = Slack.exchange_code("c0de")
  end
end
