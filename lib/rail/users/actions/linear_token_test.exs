defmodule Rail.Users.Actions.LinearTokenTest do
  use Rail.DataCase, async: true

  import RailTest.Mocks.Linear

  alias Rail.Scope
  alias Rail.Users
  alias Rail.Users.Schemas.User

  setup do
    id = System.unique_integer([:positive])

    assert {:ok, %User{id: user_id} = user} =
             Users.register_oauth_user(%{
               github_id: "token_gh_#{id}",
               login: "token_user_#{id}",
               email: "token_#{id}@example.com"
             })

    %{user: user, user_id: user_id, scope: Scope.for_user(user)}
  end

  test "returns not_linked when user has no linear credentials", %{scope: scope} do
    assert {:error, :not_linked} = Users.linear_token(scope)
  end

  test "returns not_linked when user is not found or scope invalid" do
    assert {:error, :not_linked} = Users.linear_token(nil)
    assert {:error, :not_linked} = Users.linear_token(%Scope{user: nil})
    assert {:error, :not_linked} = Users.linear_token("usr_unknown_token_id")
  end

  test "returns existing token when expiry is well in the future (> 5 minutes)", %{
    user: user,
    scope: scope
  } do
    one_hour_later = DateTime.shift(DateTime.utc_now(), hour: 1)

    assert {:ok, %User{}} =
             Users.update_user(Scope.for_system(), user, %{
               linear_access_token: "lin_at_valid_1hr",
               linear_refresh_token: "lin_rt_valid_1hr",
               linear_token_expires_at: one_hour_later
             })

    assert {:ok, "lin_at_valid_1hr"} = Users.linear_token(scope)
  end

  test "automatically refreshes token when expiry is within 5 minutes (<= 300s)", %{
    user: user,
    scope: scope,
    user_id: user_id
  } do
    two_minutes_later = DateTime.shift(DateTime.utc_now(), minute: 2)

    assert {:ok, %User{}} =
             Users.update_user(Scope.for_system(), user, %{
               linear_access_token: "lin_at_expiring_soon",
               linear_refresh_token: "lin_rt_for_refresh",
               linear_token_expires_at: two_minutes_later
             })

    mock_refresh_success(
      access_token: "lin_at_fresh_from_linear",
      refresh_token: "lin_rt_fresh_from_linear",
      expires_in: 7200
    )

    assert {:ok, "lin_at_fresh_from_linear"} = Users.linear_token(scope)

    reloaded = Repo.get!(User, user_id)
    assert reloaded.linear_access_token == "lin_at_fresh_from_linear"
    assert reloaded.linear_refresh_token == "lin_rt_fresh_from_linear"
    assert DateTime.after?(reloaded.linear_token_expires_at, DateTime.utc_now())
  end

  test "automatically refreshes token when token is already expired", %{
    user: user,
    user_id: user_id
  } do
    ten_minutes_ago = DateTime.shift(DateTime.utc_now(), minute: -10)

    assert {:ok, %User{}} =
             Users.update_user(Scope.for_system(), user, %{
               linear_access_token: "lin_at_expired",
               linear_refresh_token: "lin_rt_expired",
               linear_token_expires_at: ten_minutes_ago
             })

    mock_refresh_success(
      access_token: "lin_at_renewed",
      refresh_token: "lin_rt_renewed",
      expires_in: 3600
    )

    assert {:ok, "lin_at_renewed"} = Users.linear_token(user_id)

    reloaded = Repo.get!(User, user_id)
    assert reloaded.linear_access_token == "lin_at_renewed"
  end

  test "retains the existing refresh token when the refresh response omits one", %{user: user} do
    four_min_later = DateTime.shift(DateTime.utc_now(), minute: 4)

    assert {:ok, %User{}} =
             Users.update_user(Scope.for_system(), user, %{
               linear_access_token: "lin_at_4min",
               linear_refresh_token: "original_rt",
               linear_token_expires_at: four_min_later
             })

    Req.Test.expect(Rail.Linear, fn conn ->
      assert conn.request_path == "/oauth/token"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{
          "access_token" => "lin_at_only_access",
          "token_type" => "Bearer",
          "expires_in" => 3600
        })
      )
    end)

    assert {:ok, "lin_at_only_access"} = Users.linear_token(user)

    reloaded = Repo.get!(User, user.id)
    assert reloaded.linear_access_token == "lin_at_only_access"
    assert reloaded.linear_refresh_token == "original_rt"
  end

  test "returns error when Linear refresh fails", %{user: user, scope: scope} do
    one_min_later = DateTime.shift(DateTime.utc_now(), minute: 1)

    assert {:ok, %User{}} =
             Users.update_user(Scope.for_system(), user, %{
               linear_access_token: "lin_at_fail_refresh",
               linear_refresh_token: "lin_rt_bad",
               linear_token_expires_at: one_min_later
             })

    mock_refresh_error(400, "invalid_grant")

    assert {:error, {:linear_token_refresh_error, 400, %{"error" => "invalid_grant"}}} =
             Users.linear_token(scope)
  end

  test "returns not_linked when token needs refresh but refresh_token is missing", %{
    user: user,
    scope: scope
  } do
    one_min_later = DateTime.shift(DateTime.utc_now(), minute: 1)

    # Insert with access token but without refresh token directly via changeset
    assert {:ok, %User{}} =
             user
             |> Ecto.Changeset.change(%{
               linear_access_token: "lin_at_no_rt",
               linear_refresh_token: nil,
               linear_token_expires_at: one_min_later
             })
             |> Repo.update()

    assert {:error, :not_linked} = Users.linear_token(scope)
  end

  test "supports map-user scope", %{user: user, user_id: user_id} do
    one_hour_later = DateTime.shift(DateTime.utc_now(), hour: 1)

    assert {:ok, %User{}} =
             Users.update_user(Scope.for_system(), user, %{
               linear_access_token: "lin_at_map_scope",
               linear_refresh_token: "lin_rt_map_scope",
               linear_token_expires_at: one_hour_later
             })

    assert {:ok, "lin_at_map_scope"} = Users.linear_token(%Scope{user: %{id: user_id}})
  end

  test "stores a nil expiry when the refresh response omits expiration", %{
    user: user,
    scope: scope
  } do
    expired = DateTime.shift(DateTime.utc_now(), second: -100)

    assert {:ok, %User{}} =
             Users.update_user(Scope.for_system(), user, %{
               linear_access_token: "lin_at_expired_test",
               linear_refresh_token: "lin_rt_test",
               linear_token_expires_at: expired
             })

    Req.Test.expect(Rail.Linear, fn conn ->
      assert conn.request_path == "/oauth/token"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{
          "access_token" => "lin_at_no_exp",
          "refresh_token" => "lin_rt_no_exp"
        })
      )
    end)

    assert {:ok, "lin_at_no_exp"} = Users.linear_token(scope)

    reloaded = Repo.get!(User, user.id)
    assert reloaded.linear_access_token == "lin_at_no_exp"
    assert is_nil(reloaded.linear_token_expires_at)
  end
end
