defmodule Rail.Mcp.Utils.FetchClientTest do
  use Rail.DataCase, async: true

  import Rail.Mcp.Utils.FetchClient

  alias Rail.Mcp
  alias Rail.Mcp.Schemas.OauthClient

  setup {Req.Test, :verify_on_exit!}

  @url "https://93.184.216.34/claude/client.json"

  test "fetches a client ID metadata document, stores it, and reuses it within the day" do
    Req.Test.expect(Mcp, fn conn ->
      assert %{host: "93.184.216.34", request_path: "/claude/client.json"} = conn

      Req.Test.json(conn, %{
        "client_id" => @url,
        "client_name" => "Claude",
        "redirect_uris" => ["https://claude.ai/api/mcp/auth_callback"]
      })
    end)

    assert {:ok,
            %OauthClient{id: id, name: "Claude", registration: :metadata_document, token_endpoint_auth_method: :none}} =
             fetch_client(@url)

    assert {:ok, %OauthClient{id: ^id}} = fetch_client(@url)
  end

  test "fetches the document again once a day has passed, keeping the same client" do
    Req.Test.expect(Mcp, 2, fn conn ->
      Req.Test.json(conn, %{"client_id" => @url, "client_name" => "Claude", "redirect_uris" => ["https://claude.ai/cb"]})
    end)

    assert {:ok, %OauthClient{id: id}} = fetch_client(@url)
    Repo.update_all(OauthClient, set: [metadata_fetched_at: DateTime.shift(DateTime.utc_now(), second: -86_401)])
    assert {:ok, %OauthClient{id: ^id}} = fetch_client(@url)
  end

  test "fetches a document on a public IPv6 address" do
    url = "https://[2606:4700::1111]/client.json"

    Req.Test.expect(Mcp, fn conn ->
      Req.Test.json(conn, %{"client_id" => url, "client_name" => "Six", "redirect_uris" => ["https://claude.ai/cb"]})
    end)

    assert {:ok, %OauthClient{name: "Six"}} = fetch_client(url)
  end

  test "refuses a document on a private address without fetching it" do
    for url <- [
          "https://127.0.0.1/client.json",
          "https://10.0.0.8/client.json",
          "https://[::1]/client.json",
          "https://[fe80::1]/client.json",
          "https://[::ffff:10.0.0.1]/client.json",
          "https://no-such-host.invalid/client.json"
        ] do
      assert {:error, :invalid_client} = fetch_client(url)
    end
  end

  test "refuses a document Rail cannot trust" do
    for body <- [
          %{
            "client_id" => "https://elsewhere.example/client.json",
            "client_name" => "C",
            "redirect_uris" => ["https://a.b/c"]
          },
          %{"client_id" => @url, "client_name" => "C", "redirect_uris" => []},
          %{"client_id" => @url, "client_name" => "", "redirect_uris" => ["https://a.b/c"]},
          %{"client_id" => @url, "client_name" => "C", "redirect_uris" => ["http://a.b/c"]},
          %{
            "client_id" => @url,
            "client_name" => "C",
            "redirect_uris" => ["https://a.b/c"],
            "token_endpoint_auth_method" => "client_secret_basic"
          }
        ] do
      Req.Test.expect(Mcp, &Req.Test.json(&1, body))
      assert {:error, :invalid_client} = fetch_client(@url)
    end
  end

  test "refuses a document over 5 KB, or a host that does not answer 200" do
    Req.Test.expect(Mcp, &Plug.Conn.send_resp(&1, 200, String.duplicate("x", 6_000)))
    assert {:error, :invalid_client} = fetch_client(@url)

    Req.Test.expect(Mcp, &Plug.Conn.send_resp(&1, 404, "missing"))
    assert {:error, :invalid_client} = fetch_client(@url)
  end

  test "an https client_id with no path is looked up as a registered client" do
    assert {:error, :invalid_client} = fetch_client("https://93.184.216.34/")
    assert {:error, :invalid_client} = fetch_client(nil)
  end
end
