defmodule Rail.Users.Actions.DeleteSigningKeyTest do
  use Rail.DataCase, async: true

  alias Rail.GitHub.Client
  alias Rail.Users
  alias Rail.Users.Schemas.User

  setup do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_delete_signing_1",
        login: "ada",
        email: "ada@example.com",
        github_token: "gho_user_token"
      })

    %{user: user}
  end

  test "takes the key off GitHub and out of Rail", %{user: user} do
    Req.Test.expect(Client, fn conn ->
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => 4711})
    end)

    {:ok, user} = Users.create_signing_key(user_scope(user: user))

    Req.Test.expect(Client, fn conn ->
      assert conn.request_path == "/user/ssh_signing_keys/4711"
      Plug.Conn.send_resp(conn, 204, "")
    end)

    assert :ok = Users.delete_signing_key(user_scope(user: user))

    assert {:ok, %User{signing_key: nil, signing_public_key: nil, signing_key_github_id: nil} = forgotten} =
             Users.get_user(id: user.id)

    refute User.signing?(forgotten)
    assert User.signing_fingerprint(forgotten) == nil
  end

  test "a user with no key to remove is already where they wanted to be", %{user: user} do
    assert :ok = Users.delete_signing_key(user_scope(user: user))
  end

  test "says so when nobody is signed in" do
    assert {:error, :not_authenticated} = Users.delete_signing_key(system_scope())
  end
end
