defmodule Rail.GitHub.ClientTest do
  # Serial: some of these swap the app's key in the application env, which every
  # test minting a token reads.
  use Rail.DataCase, async: false

  alias Rail.GitHub.Client

  test "mints an app JWT backdated a minute and good for ten" do
    now = 1_700_000_000
    backdated = now - 60
    expires = now + 600

    assert {:ok, token} = Client.generate_jwt(now: now)

    assert %{"iat" => ^backdated, "exp" => ^expires, "iss" => "test_app_id"} =
             token |> String.split(".") |> Enum.at(1) |> Base.url_decode64!(padding: false) |> Jason.decode!()
  end

  test "says so when the app has no key configured" do
    original = Application.get_env(:rail, :github)
    Application.put_env(:rail, :github, Keyword.delete(original, :private_key))
    on_exit(fn -> Application.put_env(:rail, :github, original) end)

    assert {:error, :missing_github_app_private_key} = Client.generate_jwt()
  end

  test "says so when the configured key is neither a PEM nor a file" do
    original = Application.get_env(:rail, :github)
    Application.put_env(:rail, :github, Keyword.put(original, :private_key, "not-a-key"))
    on_exit(fn -> Application.put_env(:rail, :github, original) end)

    assert {:error, :invalid_github_app_private_key} = Client.generate_jwt()
  end

  test "takes the key as the PEM itself, not only as a path to one" do
    original = Application.get_env(:rail, :github)
    pem = File.read!("test/support/fixtures/github_app.pem")
    Application.put_env(:rail, :github, Keyword.put(original, :private_key, pem))
    on_exit(fn -> Application.put_env(:rail, :github, original) end)

    assert {:ok, _token} = Client.generate_jwt()
  end

  test "takes an app id configured as a number" do
    original = Application.get_env(:rail, :github)
    Application.put_env(:rail, :github, Keyword.put(original, :app_id, 4711))
    on_exit(fn -> Application.put_env(:rail, :github, original) end)

    assert {:ok, token} = Client.generate_jwt()

    assert %{"iss" => "4711"} =
             token |> String.split(".") |> Enum.at(1) |> Base.url_decode64!(padding: false) |> Jason.decode!()
  end

  test "reports a request that never reached GitHub" do
    Req.Test.expect(Client, &Req.Test.transport_error(&1, :econnrefused))

    assert {:error, %Req.TransportError{reason: :econnrefused}} = Client.installation_token(4711)

    Req.Test.expect(Client, &Req.Test.transport_error(&1, :econnrefused))

    assert {:error, %Req.TransportError{reason: :econnrefused}} =
             Client.create_signing_key("gho_user", "Rail (ada)", "ssh-ed25519 AAAA")

    Req.Test.expect(Client, &Req.Test.transport_error(&1, :econnrefused))

    assert {:error, %Req.TransportError{reason: :econnrefused}} = Client.delete_signing_key("gho_user", 99)
  end

  test "says so when the app has no id configured" do
    original = Application.get_env(:rail, :github)
    Application.put_env(:rail, :github, Keyword.delete(original, :app_id))
    on_exit(fn -> Application.put_env(:rail, :github, original) end)

    assert {:error, :missing_github_app_id} = Client.generate_jwt()
  end

  test "trades the JWT for an installation token" do
    Req.Test.expect(Client, fn conn ->
      assert conn.request_path == "/app/installations/4711/access_tokens"
      assert ["Bearer " <> _jwt] = Plug.Conn.get_req_header(conn, "authorization")

      Req.Test.json(conn, %{"token" => "ghs_installation"})
    end)

    assert {:ok, "ghs_installation"} = Client.installation_token(4711)
  end

  test "reports what GitHub said when the installation token is refused" do
    Req.Test.expect(Client, fn conn ->
      conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Not Found"})
    end)

    assert {:error, {:github_api_error, 404, %{"message" => "Not Found"}}} = Client.installation_token(4711)
  end

  test "registers a signing key on the token holder's account" do
    Req.Test.expect(Client, fn conn ->
      assert conn.request_path == "/user/ssh_signing_keys"
      assert ["Bearer gho_user"] = Plug.Conn.get_req_header(conn, "authorization")

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert %{"title" => "Rail (ada)", "key" => "ssh-ed25519 AAAA ada@example.com"} = Jason.decode!(body)

      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => 99})
    end)

    assert {:ok, 99} = Client.create_signing_key("gho_user", "Rail (ada)", "ssh-ed25519 AAAA ada@example.com")
  end

  test "a token without the signing-key scope is reported as such" do
    Req.Test.expect(Client, fn conn ->
      conn |> Plug.Conn.put_status(403) |> Req.Test.json(%{"message" => "Resource not accessible"})
    end)

    assert {:error, :missing_scope} = Client.create_signing_key("gho_user", "Rail (ada)", "ssh-ed25519 AAAA")
  end

  test "reports what GitHub said when a signing key is refused" do
    Req.Test.expect(Client, fn conn ->
      conn |> Plug.Conn.put_status(422) |> Req.Test.json(%{"message" => "key is already in use"})
    end)

    assert {:error, {:github_api_error, 422, %{"message" => "key is already in use"}}} =
             Client.create_signing_key("gho_user", "Rail (ada)", "ssh-ed25519 AAAA")
  end

  test "removes a signing key, and a key GitHub no longer has is already gone" do
    Req.Test.expect(Client, fn conn ->
      assert conn.request_path == "/user/ssh_signing_keys/99"
      Plug.Conn.send_resp(conn, 204, "")
    end)

    assert :ok = Client.delete_signing_key("gho_user", 99)

    Req.Test.expect(Client, fn conn -> Plug.Conn.send_resp(conn, 404, "") end)

    assert :ok = Client.delete_signing_key("gho_user", 99)
  end

  test "reports what GitHub said when a removal is refused" do
    Req.Test.expect(Client, fn conn ->
      conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"message" => "boom"})
    end)

    assert {:error, {:github_api_error, 500, %{"message" => "boom"}}} = Client.delete_signing_key("gho_user", 99)
  end

  test "finds the open pull request from a branch, or says there is none" do
    Req.Test.expect(Client, fn conn ->
      assert conn.request_path == "/repos/acme/app/pulls"
      assert %{"head" => "acme:dis-231", "state" => "open"} = Plug.Conn.fetch_query_params(conn).query_params
      Req.Test.json(conn, [%{"number" => 42, "html_url" => "https://github.com/acme/app/pull/42"}])
    end)

    assert {:ok, %{"number" => 42}} = Client.find_pull_request("ghs_token", "acme/app", "dis-231")

    Req.Test.expect(Client, &Req.Test.json(&1, []))
    assert {:ok, nil} = Client.find_pull_request("ghs_token", "acme/app", "dis-231")

    Req.Test.expect(Client, &(&1 |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Not Found"})))
    assert {:error, {:github_api_error, 404, _body}} = Client.find_pull_request("ghs_token", "acme/app", "dis-231")

    Req.Test.expect(Client, &Req.Test.transport_error(&1, :econnrefused))
    assert {:error, %Req.TransportError{}} = Client.find_pull_request("ghs_token", "acme/app", "dis-231")
  end

  test "opens a pull request from what GitHub takes" do
    Req.Test.expect(Client, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/repos/acme/app/pulls"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert %{"head" => "dis-231", "base" => "main", "draft" => true} = Jason.decode!(body)
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"number" => 43})
    end)

    assert {:ok, %{"number" => 43}} =
             Client.create_pull_request("ghs_token", "acme/app", %{head: "dis-231", base: "main", draft: true})

    Req.Test.expect(Client, &(&1 |> Plug.Conn.put_status(422) |> Req.Test.json(%{"message" => "Validation Failed"})))
    assert {:error, {:github_api_error, 422, _body}} = Client.create_pull_request("ghs_token", "acme/app", %{})

    Req.Test.expect(Client, &Req.Test.transport_error(&1, :econnrefused))
    assert {:error, %Req.TransportError{}} = Client.create_pull_request("ghs_token", "acme/app", %{})
  end

  test "reads one pull request by its number" do
    Req.Test.expect(Client, fn conn ->
      assert conn.request_path == "/repos/acme/app/pulls/43"
      Req.Test.json(conn, %{"number" => 43, "node_id" => "PR_kw43"})
    end)

    assert {:ok, %{"node_id" => "PR_kw43"}} = Client.get_pull_request("ghs_token", "acme/app", 43)

    Req.Test.expect(Client, &(&1 |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Not Found"})))
    assert {:error, {:github_api_error, 404, _body}} = Client.get_pull_request("ghs_token", "acme/app", 43)

    Req.Test.expect(Client, &Req.Test.transport_error(&1, :econnrefused))
    assert {:error, %Req.TransportError{}} = Client.get_pull_request("ghs_token", "acme/app", 43)
  end

  test "takes a draft out of draft through GraphQL" do
    Req.Test.expect(Client, fn conn ->
      assert conn.request_path == "/graphql"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert %{"query" => "mutation" <> _rest, "variables" => %{"id" => "PR_kw43"}} = Jason.decode!(body)
      Req.Test.json(conn, %{"data" => %{"markPullRequestReadyForReview" => %{"pullRequest" => %{"isDraft" => false}}}})
    end)

    assert :ok = Client.mark_pull_request_ready("ghs_token", "PR_kw43")

    Req.Test.expect(Client, &Req.Test.json(&1, %{"errors" => [%{"message" => "Could not resolve"}]}))
    assert {:error, {:github_api_error, 200, _body}} = Client.mark_pull_request_ready("ghs_token", "PR_kw43")

    Req.Test.expect(Client, &Req.Test.transport_error(&1, :econnrefused))
    assert {:error, %Req.TransportError{}} = Client.mark_pull_request_ready("ghs_token", "PR_kw43")
  end

  test "changes a pull request" do
    Req.Test.expect(Client, fn conn ->
      assert conn.method == "PATCH"
      assert conn.request_path == "/repos/acme/app/pulls/43"
      Req.Test.json(conn, %{"number" => 43})
    end)

    assert {:ok, %{"number" => 43}} = Client.update_pull_request("ghs_token", "acme/app", 43, %{body: "b"})

    Req.Test.expect(Client, &(&1 |> Plug.Conn.put_status(422) |> Req.Test.json(%{"message" => "Validation Failed"})))
    assert {:error, {:github_api_error, 422, _body}} = Client.update_pull_request("ghs_token", "acme/app", 43, %{})

    Req.Test.expect(Client, &Req.Test.transport_error(&1, :econnrefused))
    assert {:error, %Req.TransportError{}} = Client.update_pull_request("ghs_token", "acme/app", 43, %{})
  end
end
