defmodule Rail.Users.Actions.DeleteUserSessionTokenTest do
  use Rail.DataCase, async: true

  alias Rail.Users
  alias Rail.Users.Schemas.User

  test "deletes the specified user session token" do
    assert {:ok, user} =
             Users.register_oauth_user(%{
               github_id: "del_tok_gh",
               login: "del_tok_user",
               email: "deltok@example.com"
             })

    token = Users.generate_user_session_token(user)
    assert {%User{}, _inserted_at} = Users.get_user_by_session_token(token)

    assert :ok = Users.delete_user_session_token(token)
    assert is_nil(Users.get_user_by_session_token(token))
  end
end
