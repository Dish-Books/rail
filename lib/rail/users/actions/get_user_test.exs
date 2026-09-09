defmodule Rail.Users.Actions.GetUserTest do
  use Rail.DataCase, async: true

  alias Rail.Users
  alias Rail.Users.Schemas.User

  test "get_user/1 finds user by id" do
    assert {:ok, %User{id: user_id}} =
             Users.register_oauth_user(%{
               github_id: "get_user_1",
               login: "get_user_login",
               email: "getuser@example.com"
             })

    assert {:ok, %User{id: ^user_id}} = Users.get_user(user_id)
    assert {:error, :not_found} = Users.get_user("usr_nonexistent")
  end

  test "get_user/1 finds user by keyword list" do
    assert {:ok, %User{id: user_id, email: "keyword@example.com"}} =
             Users.register_oauth_user(%{
               github_id: "get_user_kw",
               login: "get_user_kw",
               email: "keyword@example.com"
             })

    assert {:ok, %User{id: ^user_id}} = Users.get_user(email: "keyword@example.com")
    assert {:error, :not_found} = Users.get_user(email: "nonexistent@example.com")
  end

  test "get_user!/1 returns user or raises" do
    assert {:ok, %User{id: user_id}} =
             Users.register_oauth_user(%{
               github_id: "get_user_bang",
               login: "get_user_bang",
               email: "getuserbang@example.com"
             })

    assert %User{id: ^user_id} = Users.get_user!(user_id)

    assert_raise Ecto.NoResultsError, fn ->
      Users.get_user!("usr_nonexistent")
    end
  end
end
