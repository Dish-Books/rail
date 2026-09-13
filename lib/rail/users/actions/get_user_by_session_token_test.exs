defmodule Rail.Users.Actions.GetUserBySessionTokenTest do
  use Rail.DataCase, async: true

  alias Rail.Users
  alias Rail.Users.Schemas.User
  alias Rail.Users.Schemas.UserToken

  test "returns user and token_inserted_at for valid session token" do
    assert {:ok, %User{id: user_id} = user} =
             Users.register_oauth_user(%{
               github_id: "token_lookup_gh",
               login: "token_lookup",
               email: "tokenlookup@example.com"
             })

    token = Users.generate_user_session_token(user)

    assert {%User{id: ^user_id}, %DateTime{}} = Users.get_user_by_session_token(token)
  end

  test "returns nil for nonexistent token" do
    assert is_nil(Users.get_user_by_session_token(:crypto.strong_rand_bytes(32)))
  end

  test "returns nil for non-binary input" do
    assert is_nil(Users.get_user_by_session_token(nil))
    assert is_nil(Users.get_user_by_session_token(12_345))
  end

  test "returns nil for expired session token" do
    assert {:ok, user} =
             Users.register_oauth_user(%{
               github_id: "token_expired_gh",
               login: "token_expired",
               email: "tokenexpired@example.com"
             })

    {token, user_token} = UserToken.build_session_token(user)

    expired_at =
      DateTime.shift(DateTime.utc_now(), day: -(UserToken.session_validity_in_days() + 1))

    Repo.insert!(%{user_token | inserted_at: expired_at})

    assert is_nil(Users.get_user_by_session_token(token))
  end
end
