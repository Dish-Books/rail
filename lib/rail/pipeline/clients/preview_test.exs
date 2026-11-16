defmodule Rail.Pipeline.Clients.PreviewTest do
  use Rail.DataCase, async: true

  alias Rail.Pipeline.Clients.Preview, as: Client

  setup do
    %{access: %{client_id: "id.access", client_secret: "secret"}}
  end

  test "the commit a deployment serves is read from its /version, with the Access token when there is one", %{
    access: access
  } do
    Req.Test.expect(Client, fn conn ->
      assert conn.host == "pr-7.preview.example.com"
      assert conn.request_path == "/version"
      assert Plug.Conn.get_req_header(conn, "cf-access-client-id") == ["id.access"]
      assert Plug.Conn.get_req_header(conn, "cf-access-client-secret") == ["secret"]
      Req.Test.json(conn, %{"sha" => "abc123"})
    end)

    assert {:ok, "abc123"} = Client.version("https://pr-7.preview.example.com", access)

    Req.Test.expect(Client, fn conn ->
      assert Plug.Conn.get_req_header(conn, "cf-access-client-id") == []
      Req.Test.json(conn, %{"sha" => "def456"})
    end)

    assert {:ok, "def456"} = Client.version("https://pr-7.preview.example.com", nil)
  end

  # Access answers a request it turns away with a redirect to its login, which is not followed.
  test "a deployment that answers anything else, or cannot be reached, says why" do
    Req.Test.expect(Client, fn conn ->
      conn |> Plug.Conn.put_resp_header("location", "/login") |> Plug.Conn.send_resp(302, "")
    end)

    assert {:error, {:preview_status, 302}} = Client.version("https://pr-7.preview.example.com", nil)

    Req.Test.expect(Client, &Req.Test.json(&1, %{"version" => "1.0"}))
    assert {:error, {:preview_status, 200}} = Client.version("https://pr-7.preview.example.com", nil)

    Req.Test.expect(Client, &Req.Test.transport_error(&1, :econnrefused))
    assert {:error, %Req.TransportError{reason: :econnrefused}} = Client.version("https://pr-7.preview.example.com", nil)
  end

  test "a project without an Access token needs no cookie, and asks nothing" do
    assert {:ok, []} = Client.access_cookies("https://pr-7.preview.example.com", nil)
  end

  test "the cookie Access sets for the token is handed on for the deployment's host alone", %{access: access} do
    Req.Test.expect(Client, fn conn ->
      assert Plug.Conn.get_req_header(conn, "cf-access-client-id") == ["id.access"]

      conn
      |> Plug.Conn.prepend_resp_headers([
        {"set-cookie", "other=1; Path=/"},
        {"set-cookie", "CF_Authorization=eyJ.jwt.sig; Path=/; Secure; HttpOnly"}
      ])
      |> Req.Test.json(%{"sha" => "abc123"})
    end)

    assert {:ok,
            [
              %{
                name: "CF_Authorization",
                value: "eyJ.jwt.sig",
                domain: "pr-7.preview.example.com",
                path: "/",
                secure: true,
                httpOnly: true
              }
            ]} = Client.access_cookies("https://pr-7.preview.example.com", access)
  end

  test "an answer without the Access cookie, or none at all, opens nothing", %{access: access} do
    Req.Test.expect(Client, &Req.Test.json(&1, %{"sha" => "abc123"}))
    assert {:error, :no_access_cookie} = Client.access_cookies("https://pr-7.preview.example.com", access)

    Req.Test.expect(Client, &Req.Test.transport_error(&1, :timeout))

    assert {:error, %Req.TransportError{reason: :timeout}} =
             Client.access_cookies("https://pr-7.preview.example.com", access)
  end
end
