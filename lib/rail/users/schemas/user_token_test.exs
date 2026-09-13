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

    assert {token, %UserToken{context: "session", user_id: ^user_id} = user_token} =
             UserToken.build_session_token(%User{id: user_id})

    assert byte_size(token) == 32

    digest = :crypto.hash(:sha256, token)
    assert %UserToken{token: ^digest} = user_token
    refute user_token.token == token
  end

  test "build_session_token never stores the raw token" do
    assert {:ok, user} =
             Users.register_oauth_user(%{
               github_id: "raw_tok_gh",
               login: "raw_tok_user",
               email: "rawtok@example.com"
             })

    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)

    assert is_nil(Repo.get_by(UserToken, token: token))
    assert %UserToken{} = Repo.get_by(UserToken, token: :crypto.hash(:sha256, token))
  end
end
