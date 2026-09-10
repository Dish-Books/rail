defmodule Rail.Users.Schemas.UserTokenTest do
  use Rail.DataCase, async: true

  alias Rail.Users
  alias Rail.Users.Schemas.User
  alias Rail.Users.Schemas.UserToken

  test "build_session_token builds a session token struct for user" do
    assert {:ok, %User{id: user_id}} =
             Users.register_oauth_user(%{
               github_id: "tok_test_user_gh",
               login: "tok_user",
               email: "tokuser@example.com"
             })

    assert {token, %UserToken{token: token, context: "session", user_id: ^user_id}} =
             UserToken.build_session_token(%User{id: user_id})

    assert byte_size(token) == 32
  end

  test "verify_session_token_query returns query that finds valid token" do
    assert {:ok, %User{id: user_id} = user} =
             Users.register_oauth_user(%{
               github_id: "verify_tok_gh",
               login: "verify_user",
               email: "verifyuser@example.com"
             })

    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)

    assert {:ok, query} = UserToken.verify_session_token_query(token)
    assert {%{id: ^user_id}, _inserted_at} = Repo.one(query)
  end

  test "verify_session_token_query excludes expired tokens" do
    assert {:ok, user} =
             Users.register_oauth_user(%{
               github_id: "expired_tok_gh",
               login: "expired_user",
               email: "expireduser@example.com"
             })

    {token, user_token} = UserToken.build_session_token(user)

    fifteen_days_ago = DateTime.shift(DateTime.utc_now(), day: -15)

    Repo.insert!(%{user_token | inserted_at: fifteen_days_ago})

    assert {:ok, query} = UserToken.verify_session_token_query(token)
    assert is_nil(Repo.one(query))
  end
end
