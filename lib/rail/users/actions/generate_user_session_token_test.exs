defmodule Rail.Users.Actions.GenerateUserSessionTokenTest do
  use Rail.DataCase, async: true

  alias Rail.Users
  alias Rail.Users.Schemas.User

  test "generates a session token and stores it in the database" do
    assert {:ok, %User{id: user_id} = user} =
             Users.register_oauth_user(%{
               github_id: "gen_tok_gh",
               login: "gen_tok_user",
               email: "gentok@example.com"
             })

    token = Users.generate_user_session_token(user)

    assert byte_size(token) == 32
    assert {%User{id: ^user_id}, _inserted_at} = Users.get_user_by_session_token(token)
  end
end
