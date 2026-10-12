defmodule Rail.Users.Actions.GitHubTokenTest do
  use Rail.DataCase, async: true

  alias Rail.GitHub.Client
  alias Rail.Scope
  alias Rail.Users
  alias Rail.Users.Schemas.User

  setup do
    id = System.unique_integer([:positive])

    assert {:ok, %User{} = user} =
             Users.register_oauth_user(%{
               github_id: "gh_token_#{id}",
               login: "gh_token_user_#{id}",
               email: "gh_token_#{id}@example.com",
               github_token: "ghu_stored",
               github_refresh_token: "ghr_stored",
               github_token_expires_at: DateTime.shift(DateTime.utc_now(), minute: -10)
             })

    %{user: user, scope: Scope.for_user(user)}
  end

  test "a token with time left is used as it is, and GitHub is not asked", %{user: user, scope: scope} do
    {:ok, _fresh} =
      Users.update_user(system_scope(), user, %{github_token_expires_at: DateTime.shift(DateTime.utc_now(), hour: 1)})

    assert {:ok, "ghu_stored"} = Users.github_token(scope)
  end

  test "an expired token is renewed, and the new access and refresh tokens are saved with the new expiry", %{
    user: user,
    scope: scope
  } do
    Req.Test.expect(Client, fn conn ->
      assert {conn.method, conn.host, conn.request_path} == {"POST", "github.com", "/login/oauth/access_token"}
      assert ["application/json"] = Plug.Conn.get_req_header(conn, "accept")
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert %{
               "grant_type" => "refresh_token",
               "refresh_token" => "ghr_stored",
               "client_id" => "" <> _id,
               "client_secret" => "" <> _secret
             } = URI.decode_query(body)

      Req.Test.json(conn, %{
        "access_token" => "ghu_renewed",
        "expires_in" => 28_800,
        "refresh_token" => "ghr_renewed",
        "refresh_token_expires_in" => 15_897_600
      })
    end)

    assert {:ok, "ghu_renewed"} = Users.github_token(scope)

    assert %User{github_token: "ghu_renewed", github_refresh_token: "ghr_renewed", github_token_expires_at: expires_at} =
             Repo.get!(User, user.id)

    assert DateTime.diff(expires_at, DateTime.utc_now(), :minute) in 478..480
    # Fresh now, so the next caller is handed it without another renewal.
    assert {:ok, "ghu_renewed"} = Users.github_token(scope)
  end

  test "a token about to expire is renewed, keeping the refresh token and no expiry when GitHub sends neither", %{
    user: user,
    scope: scope
  } do
    {:ok, _expiring} =
      Users.update_user(system_scope(), user, %{github_token_expires_at: DateTime.shift(DateTime.utc_now(), minute: 2)})

    Req.Test.expect(Client, &Req.Test.json(&1, %{"access_token" => "ghu_only"}))

    assert {:ok, "ghu_only"} = Users.github_token(scope)

    assert %User{github_token: "ghu_only", github_refresh_token: "ghr_stored", github_token_expires_at: nil} =
             Repo.get!(User, user.id)
  end

  test "a renewal GitHub refuses is someone who signs in again, and what Rail held is left as it was", %{
    user: user,
    scope: scope
  } do
    Req.Test.expect(Client, fn conn ->
      Req.Test.json(conn, %{
        "error" => "bad_refresh_token",
        "error_description" => "The refresh token passed is incorrect or expired."
      })
    end)

    assert {:error, :no_github_token} = Users.github_token(scope)
    assert %User{github_token: "ghu_stored", github_refresh_token: "ghr_stored"} = Repo.get!(User, user.id)
  end

  test "a renewal that GitHub could not answer returns its error, to be tried again", %{scope: scope} do
    Req.Test.expect(Client, &(&1 |> Plug.Conn.put_status(503) |> Req.Test.json(%{})))
    assert {:error, {:github_token_refresh_error, 503, _body}} = Users.github_token(scope)

    Req.Test.expect(Client, &Req.Test.transport_error(&1, :econnrefused))
    assert {:error, %Req.TransportError{reason: :econnrefused}} = Users.github_token(scope)
  end

  test "someone signed in before Rail kept a refresh token signs in again, and GitHub is not asked", %{
    user: user,
    scope: scope
  } do
    {:ok, _legacy} =
      user |> Ecto.Changeset.change(%{github_refresh_token: nil, github_token_expires_at: nil}) |> Repo.update()

    assert {:error, :no_github_token} = Users.github_token(scope)
  end

  test "someone with no token, someone Rail does not know, and the system have none", %{user: user, scope: scope} do
    {:ok, _tokenless} = user |> Ecto.Changeset.change(%{github_token: nil}) |> Repo.update()

    assert {:error, :no_github_token} = Users.github_token(scope)
    assert {:error, :no_github_token} = Users.github_token(%Scope{user: %{id: "usr_unknown_github_token"}})
    assert {:error, :no_github_token} = Users.github_token(system_scope())
  end

  # GitHub spends a refresh token on use, so a second renewal that did not wait would send one already spent.
  test "two renewals at once spend the refresh token once, and both get the new token", %{scope: scope} do
    test_pid = self()

    Req.Test.stub(Client, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:held, self(), URI.decode_query(body)["refresh_token"]})
      assert_receive :answer, 2_000
      Req.Test.json(conn, %{"access_token" => "ghu_renewed", "expires_in" => 28_800, "refresh_token" => "ghr_renewed"})
    end)

    first = Elixir.Task.async(fn -> Users.github_token(scope) end)
    second = Elixir.Task.async(fn -> Users.github_token(scope) end)

    assert_receive {:held, held, "ghr_stored"}, 2_000
    refute_receive {:held, _other, _refresh_token}, 200
    send(held, :answer)

    assert {:ok, "ghu_renewed"} = Elixir.Task.await(first)
    assert {:ok, "ghu_renewed"} = Elixir.Task.await(second)
    refute_received {:held, _other, _refresh_token}
  end
end
