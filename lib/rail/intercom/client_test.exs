defmodule Rail.Intercom.ClientTest do
  use Rail.DataCase, async: true

  alias Rail.Intercom
  alias Rail.Support.Schemas.IntercomWorkspace

  setup do
    %{
      workspace: %IntercomWorkspace{
        external_id: "app_client",
        access_token: "tok_workspace",
        client_id: "cid_1",
        client_secret: "secret_1"
      }
    }
  end

  test "me reads who a token belongs to, on that token and Intercom's API version" do
    Req.Test.expect(Intercom, fn conn ->
      assert conn.request_path == "/me"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer tok_person"]
      assert Plug.Conn.get_req_header(conn, "intercom-version") == ["2.11"]
      Req.Test.json(conn, %{"id" => "42", "app" => %{"id_code" => "app_client"}})
    end)

    assert {:ok, %{"id" => "42", "app" => %{"id_code" => "app_client"}}} = Intercom.me("tok_person")
  end

  test "a refused call is an error naming the status and body" do
    Req.Test.expect(Intercom, &(&1 |> Plug.Conn.put_status(401) |> Req.Test.json(%{"type" => "error.list"})))

    assert {:error, {:intercom_error, 401, %{"type" => "error.list"}}} = Intercom.me("tok_bad")
  end

  test "an Intercom that cannot be reached is an error" do
    Req.Test.expect(Intercom, &Req.Test.transport_error(&1, :econnrefused))

    assert {:error, %Req.TransportError{reason: :econnrefused}} = Intercom.me("tok_person")
  end

  test "lists a page of conversations and the cursor of the next", %{workspace: workspace} do
    Req.Test.expect(Intercom, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.request_path == "/conversations"
      assert %{"per_page" => "150", "starting_after" => "cur_1"} = conn.query_params
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer tok_workspace"]

      Req.Test.json(conn, %{
        "conversations" => [%{"id" => "1"}, %{"id" => "2"}],
        "pages" => %{"next" => %{"starting_after" => "cur_2"}}
      })
    end)

    assert {:ok, [%{"id" => "1"}, %{"id" => "2"}], "cur_2"} = Intercom.list_conversations(workspace, "cur_1")
  end

  test "the first page sends no cursor, and the last has none", %{workspace: workspace} do
    Req.Test.expect(Intercom, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      refute Map.has_key?(conn.query_params, "starting_after")
      Req.Test.json(conn, %{"pages" => %{}})
    end)

    assert {:ok, [], nil} = Intercom.list_conversations(workspace, nil)
  end

  test "a list Intercom refuses is an error", %{workspace: workspace} do
    Req.Test.expect(Intercom, &Plug.Conn.send_resp(&1, 500, "down"))

    assert {:error, {:intercom_error, 500, "down"}} = Intercom.list_conversations(workspace, nil)
  end

  test "reads one conversation", %{workspace: workspace} do
    Req.Test.expect(Intercom, fn conn ->
      assert conn.request_path == "/conversations/c9"
      Req.Test.json(conn, %{"id" => "c9", "updated_at" => 1})
    end)

    assert {:ok, %{"id" => "c9"}} = Intercom.get_conversation(workspace, "c9")
  end

  test "replies as the teammate, with their own token" do
    Req.Test.expect(Intercom, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/conversations/c9/reply"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer tok_person"]
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert %{"message_type" => "comment", "type" => "admin", "admin_id" => "77", "body" => "<p>Hi</p>"} =
               Jason.decode!(body)

      Req.Test.json(conn, %{"type" => "conversation"})
    end)

    assert {:ok, %{"type" => "conversation"}} = Intercom.reply("tok_person", "c9", "77", "<p>Hi</p>")
  end

  test "downloads a file with the workspace's token, as raw bytes", %{workspace: workspace} do
    Req.Test.expect(Intercom, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer tok_workspace"]
      conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.send_resp(200, "{\"not\":1}")
    end)

    assert {:ok, "{\"not\":1}"} = Intercom.download_file(workspace, "https://downloads.intercomcdn.com/f.json")
  end

  test "refuses a file outside Intercom's hosts, without a request", %{workspace: workspace} do
    for url <- [
          "https://attacker.example/x.png",
          "https://intercomcdn.com.attacker.example/x.png",
          "http://downloads.intercomcdn.com/f.png",
          "javascript:alert(1)"
        ] do
      assert {:error, :not_an_intercom_file} = Intercom.download_file(workspace, url)
    end
  end

  test "the authorize URL carries the app's client id, the state and Rail's callback", %{workspace: workspace} do
    assert "https://app.intercom.com/oauth?" <> query = Intercom.authorize_url(workspace, "st_1")

    assert %{"client_id" => "cid_1", "state" => "st_1", "redirect_uri" => "http" <> redirect} = URI.decode_query(query)
    assert String.ends_with?(redirect, "/auth/intercom/callback")
  end

  test "exchanges a code for a token with the app's client id and secret", %{workspace: workspace} do
    Req.Test.expect(Intercom, fn conn ->
      assert conn.request_path == "/auth/eagle/token"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert %{"code" => "code_1", "client_id" => "cid_1", "client_secret" => "secret_1"} = URI.decode_query(body)
      Req.Test.json(conn, %{"access_token" => "tok_person"})
    end)

    assert {:ok, %{"access_token" => "tok_person"}} = Intercom.exchange_code(workspace, "code_1")
  end
end
