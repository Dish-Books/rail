defmodule Rail.Users.Actions.RegisterOAuthUserTest do
  use Rail.DataCase, async: true

  alias Rail.Users
  alias Rail.Users.Schemas.User
  alias Ueberauth.Auth.Credentials
  alias Ueberauth.Auth.Info

  test "first registered user receives admin: true" do
    attrs = %{
      github_id: "1001",
      login: "first_user",
      name: "First User",
      email: "first@example.com",
      github_token: "gho_token_1"
    }

    assert {:ok, %User{github_id: "1001", admin: true}} = Users.register_oauth_user(attrs)
  end

  test "subsequent registered users receive admin: false by default" do
    assert {:ok, %User{admin: true}} =
             Users.register_oauth_user(%{
               github_id: "2001",
               login: "first_user_2",
               email: "first2@example.com"
             })

    assert {:ok, %User{github_id: "2002", admin: false}} =
             Users.register_oauth_user(%{
               github_id: "2002",
               login: "second_user",
               email: "second@example.com"
             })
  end

  test "registers user from Ueberauth.Auth struct" do
    auth = %Ueberauth.Auth{
      provider: :github,
      uid: 99_999,
      info: %Info{
        nickname: "octocat_auth",
        name: "Octocat Auth",
        email: "octocat_auth@github.com",
        image: "https://example.com/octocat.png"
      },
      credentials: %Credentials{
        token: "gho_ueberauth_token"
      }
    }

    assert {:ok,
            %User{
              github_id: "99999",
              login: "octocat_auth",
              name: "Octocat Auth",
              email: "octocat_auth@github.com",
              avatar_url: "https://example.com/octocat.png"
            } = user} = Users.register_oauth_user(auth)

    # Token is encrypted and matches when loaded
    reloaded = Repo.get!(User, user.id)
    assert reloaded.github_token == "gho_ueberauth_token"
  end

  test "updates existing user by github_id and preserves admin status" do
    assert {:ok, %User{id: user_id, admin: true}} =
             Users.register_oauth_user(%{
               github_id: "3001",
               login: "orig_login",
               name: "Original Name",
               email: "orig@example.com",
               github_token: "token_1"
             })

    assert {:ok,
            %User{
              id: ^user_id,
              login: "new_login",
              name: "New Name",
              email: "new@example.com",
              admin: true
            } = updated_user} =
             Users.register_oauth_user(%{
               github_id: "3001",
               login: "new_login",
               name: "New Name",
               email: "new@example.com",
               github_token: "token_2"
             })

    reloaded = Repo.get!(User, updated_user.id)
    assert reloaded.github_token == "token_2"
  end

  test "matches and updates existing user by email when github_id differs" do
    assert {:ok, %User{id: user_id}} =
             Users.register_oauth_user(%{
               github_id: "4001",
               login: "email_match_old",
               name: "Same Email",
               email: "shared@example.com"
             })

    assert {:ok, %User{id: ^user_id, login: "email_match_new"}} =
             Users.register_oauth_user(%{
               github_id: "4001",
               login: "email_match_new",
               name: "Same Email",
               email: "shared@example.com"
             })
  end

  test "registers user from Ueberauth.Auth with raw_info avatar fallback" do
    auth = %Ueberauth.Auth{
      provider: :github,
      uid: 88_888,
      info: %Info{
        nickname: "raw_avatar_user",
        name: "Raw Avatar",
        email: "raw_avatar@github.com",
        image: nil
      },
      extra: %Ueberauth.Auth.Extra{
        raw_info: %{
          user: %{"avatar_url" => "https://example.com/raw_avatar.png"}
        }
      },
      credentials: %Credentials{
        token: "gho_raw_token"
      }
    }

    assert {:ok, %User{avatar_url: "https://example.com/raw_avatar.png"}} =
             Users.register_oauth_user(auth)
  end

  test "updates existing user with explicit admin flag" do
    assert {:ok, %User{id: user_id, admin: true}} =
             Users.register_oauth_user(%{
               github_id: "admin_up_gh",
               login: "admin_up_user",
               email: "adminup@example.com"
             })

    assert {:ok, %User{id: ^user_id, admin: false}} =
             Users.register_oauth_user(%{
               github_id: "admin_up_gh",
               login: "admin_up_user",
               email: "adminup@example.com",
               admin: false
             })
  end

  test "returns changeset error on invalid update attributes" do
    assert {:ok, %User{}} =
             Users.register_oauth_user(%{
               github_id: "bad_up_gh",
               login: "bad_up_user",
               email: "badup@example.com"
             })

    assert {:error, changeset} =
             Users.register_oauth_user(%{
               github_id: "bad_up_gh",
               login: "",
               email: "badup@example.com"
             })

    assert %{login: ["can't be blank"]} = errors_on(changeset)
  end

  test "returns changeset error on invalid attributes" do
    assert {:error, changeset} = Users.register_oauth_user(%{})
    assert %{github_id: ["can't be blank"]} = errors_on(changeset)
  end

  test "normalizes integer github_id in map attrs" do
    assert {:ok, %User{github_id: "12345"}} =
             Users.register_oauth_user(%{
               github_id: 12_345,
               login: "int_gh_user",
               email: "intgh@example.com"
             })
  end
end
