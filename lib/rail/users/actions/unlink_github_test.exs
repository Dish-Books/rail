defmodule Rail.Users.Actions.UnlinkGitHubTest do
  use Rail.DataCase, async: true

  alias Rail.GitHub.Client
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users
  alias Rail.Users.Schemas.User

  setup {Req.Test, :verify_on_exit!}

  setup do
    id = System.unique_integer([:positive])

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_unlink_#{id}",
        login: "unlink-#{id}",
        name: "Mira Lane",
        email: "mira-#{id}@x.io",
        avatar_url: "https://avatars.example/mira.png"
      })

    {:ok, user} =
      Users.update_user(Scope.for_system(), user, %{
        signing_key: "private",
        signing_public_key: "ssh-ed25519 AAAA rail",
        signing_key_github_id: 4711
      })

    %{user: user}
  end

  test "takes the signing key off GitHub and forgets the account, leaving the user", %{user: user} do
    {:ok, %User{id: user_id, email: email} = user} =
      Users.update_user(Scope.for_system(), user, %{
        github_token: "gho_mira",
        github_refresh_token: "ghr_mira",
        github_token_expires_at: ~U[2100-01-01 00:00:00.000000Z]
      })

    Req.Test.expect(Client, fn %{method: "DELETE", request_path: "/user/ssh_signing_keys/4711"} = conn ->
      Plug.Conn.send_resp(conn, 204, "")
    end)

    Phoenix.PubSub.subscribe(Rail.PubSub, "users")

    assert {:ok, %User{id: ^user_id, email: ^email, name: "Mira Lane", github_id: nil, login: nil, avatar_url: nil}} =
             Users.unlink_github(Scope.for_user(user))

    assert %User{github_token: nil, github_refresh_token: nil, github_token_expires_at: nil, signing_key: nil} =
             Repo.get!(User, user_id)

    assert_receive {:users_changed, ^user_id}
  end

  test "forgets the account and the key even when GitHub cannot be reached to delete it", %{user: user} do
    assert {:ok, %User{github_id: nil, login: nil, signing_key: nil, signing_key_github_id: nil}} =
             Users.unlink_github(Scope.for_user(user))
  end
end
