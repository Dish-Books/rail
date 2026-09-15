defmodule Rail.Users.Actions.CreateSigningKeyTest do
  use Rail.DataCase, async: true

  alias Rail.GitHub.Client
  alias Rail.Users
  alias Rail.Users.Schemas.User

  setup do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_signing_1",
        login: "ada",
        email: "ada@example.com",
        github_token: "gho_user_token"
      })

    %{scope: user_scope(user: user)}
  end

  test "generates a key and registers it on the user's GitHub account", %{scope: scope} do
    Req.Test.expect(Client, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert %{"title" => "Rail (ada)", "key" => "ssh-ed25519 " <> _rest} = Jason.decode!(body)

      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => 4711})
    end)

    assert {:ok,
            %User{
              signing_key_github_id: 4711,
              signing_key: "-----BEGIN OPENSSH PRIVATE KEY-----" <> _private,
              signing_public_key: "ssh-ed25519 " <> _public
            } = user} = Users.create_signing_key(scope)

    assert User.signing?(user)
    assert User.signing_fingerprint(user) =~ "SHA256:"
  end

  test "keeps the private half out of anything that gets logged", %{scope: scope} do
    Req.Test.expect(Client, fn conn ->
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => 4711})
    end)

    {:ok, user} = Users.create_signing_key(scope)

    refute inspect(user) =~ "PRIVATE KEY"
  end

  test "takes the old key off GitHub before registering a new one", %{scope: scope} do
    Req.Test.expect(Client, fn conn ->
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => 1})
    end)

    assert {:ok, %User{signing_key: first_key} = user} = Users.create_signing_key(scope)

    Req.Test.expect(Client, fn conn ->
      assert conn.method == "DELETE"
      assert conn.request_path == "/user/ssh_signing_keys/1"
      Plug.Conn.send_resp(conn, 204, "")
    end)

    Req.Test.expect(Client, fn conn ->
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => 2})
    end)

    assert {:ok, %User{signing_key_github_id: 2, signing_key: rekeyed}} = Users.create_signing_key(user_scope(user: user))
    refute rekeyed == first_key
  end

  test "says so when GitHub has not granted Rail the signing-key scope", %{scope: scope} do
    Req.Test.expect(Client, fn conn ->
      conn |> Plug.Conn.put_status(403) |> Req.Test.json(%{"message" => "Resource not accessible"})
    end)

    assert {:error, :missing_scope} = Users.create_signing_key(scope)
  end

  test "says so when the user has no GitHub token" do
    {:ok, user} =
      Users.register_oauth_user(%{github_id: "gh_signing_2", login: "grace", email: "grace@example.com"})

    assert {:error, :no_github_token} = Users.create_signing_key(user_scope(user: user))
  end

  test "says so when nobody is signed in" do
    assert {:error, :not_authenticated} = Users.create_signing_key(system_scope())
  end
end
