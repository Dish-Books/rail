defmodule Rail.Users.Actions.LinkLinearTest do
  use Rail.DataCase, async: true

  alias Rail.Scope
  alias Rail.Users
  alias Rail.Users.Schemas.User

  setup do
    {:ok, user} =
      Users.register_oauth_user(%{github_id: "gh_link_linear", login: "link_linear", email: "link_linear@example.com"})

    %{user: user, scope: Scope.for_user(user)}
  end

  test "trades the code for tokens and stores them with who they belong to", %{scope: scope} do
    Req.Test.expect(Rail.Linear, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert %{"grant_type" => "authorization_code", "code" => "good_code"} = URI.decode_query(body)

      Req.Test.json(conn, %{"access_token" => "lin_at", "refresh_token" => "lin_rt", "expires_in" => 3600})
    end)

    Req.Test.expect(Rail.Linear, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer lin_at"]
      Req.Test.json(conn, %{"data" => %{"viewer" => %{"id" => "lin_usr_1", "name" => "Linear Person"}}})
    end)

    assert {:ok,
            %User{
              linear_user_id: "lin_usr_1",
              linear_name: "Linear Person",
              linear_access_token: "lin_at",
              linear_refresh_token: "lin_rt",
              linear_token_expires_at: %DateTime{} = expires_at
            }} = Users.link_linear(scope, "good_code")

    assert DateTime.after?(expires_at, DateTime.utc_now())
  end

  test "stores no expiry when Linear gives none", %{scope: scope} do
    Req.Test.expect(Rail.Linear, fn conn -> Req.Test.json(conn, %{"access_token" => "lin_at_forever"}) end)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"viewer" => %{"id" => "lin_usr_2", "name" => "Forever"}}})
    end)

    assert {:ok, %User{linear_access_token: "lin_at_forever", linear_token_expires_at: nil}} =
             Users.link_linear(scope, "code")
  end

  test "links nothing when the code exchange fails", %{scope: scope, user: user} do
    Req.Test.expect(Rail.Linear, fn conn ->
      conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "invalid_grant"})
    end)

    assert {:error, {:linear_oauth_error, 400, _body}} = Users.link_linear(scope, "bad_code")
    assert %User{linear_access_token: nil} = Repo.reload!(user)
  end

  test "links nothing when the viewer cannot be read", %{scope: scope, user: user} do
    Req.Test.expect(Rail.Linear, fn conn -> Req.Test.json(conn, %{"access_token" => "lin_at"}) end)

    Req.Test.expect(Rail.Linear, fn conn ->
      conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"errors" => [%{"message" => "Not authenticated"}]})
    end)

    assert {:error, {:linear_api_error, 401, _body}} = Users.link_linear(scope, "code")
    assert %User{linear_access_token: nil} = Repo.reload!(user)
  end

  test "needs a signed-in user" do
    assert {:error, :not_authenticated} = Users.link_linear(Scope.for_system(), "code")
  end
end
