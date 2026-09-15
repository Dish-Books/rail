defmodule Rail.Users.Schemas.UserTest do
  use Rail.DataCase, async: true

  alias Rail.Users
  alias Rail.Users.Schemas.User

  test "changeset validates required fields" do
    changeset = User.changeset(%User{}, %{})

    assert %{
             github_id: ["can't be blank"],
             login: ["can't be blank"],
             email: ["can't be blank"]
           } = errors_on(changeset)
  end

  test "changeset accepts valid attributes" do
    attrs = %{
      github_id: "12345",
      login: "octocat",
      name: "Mona Lisa",
      email: "octocat@github.com",
      avatar_url: "https://example.com/avatar.png",
      github_token: "gho_secret123",
      admin: true
    }

    assert User.changeset(%User{}, attrs).valid?
  end

  test "changeset enforces uniqueness on github_id, login, and email" do
    assert {:ok, %User{github_id: github_id, login: login, email: email}} =
             Users.register_oauth_user(%{
               github_id: "unique_gh_id",
               login: "unique_login",
               email: "unique@example.com"
             })

    assert {:error, changeset1} =
             %User{}
             |> User.changeset(%{github_id: github_id, login: "other1", email: "other1@example.com"})
             |> Repo.insert()

    assert %{github_id: ["has already been taken"]} = errors_on(changeset1)

    assert {:error, changeset2} =
             %User{}
             |> User.changeset(%{github_id: "other2", login: login, email: "other2@example.com"})
             |> Repo.insert()

    assert %{login: ["has already been taken"]} = errors_on(changeset2)

    assert {:error, changeset3} =
             %User{}
             |> User.changeset(%{github_id: "other3", login: "other3", email: email})
             |> Repo.insert()

    assert %{email: ["has already been taken"]} = errors_on(changeset3)
  end

  test "changeset clears every Linear credential at once" do
    user = %User{
      github_id: "g",
      login: "l",
      email: "e",
      linear_user_id: "lin_usr_1",
      linear_name: "Lin Name",
      linear_access_token: "lin_at",
      linear_refresh_token: "lin_rt",
      linear_token_expires_at: DateTime.utc_now()
    }

    changeset =
      User.changeset(user, %{
        linear_user_id: nil,
        linear_name: nil,
        linear_access_token: nil,
        linear_refresh_token: nil,
        linear_token_expires_at: nil
      })

    assert changeset.valid?

    assert changeset.changes == %{
             linear_user_id: nil,
             linear_name: nil,
             linear_access_token: nil,
             linear_refresh_token: nil,
             linear_token_expires_at: nil
           }
  end

  test "redacts sensitive fields on inspect" do
    assert {:ok, user} =
             Users.register_oauth_user(%{
               github_id: "redact_test_gh",
               login: "redact_test",
               email: "redact@example.com",
               github_token: "super-secret-token"
             })

    inspected = inspect(user)
    refute String.contains?(inspected, "super-secret-token")
    refute String.contains?(inspected, "github_token:")
  end

  test "redacts linear tokens on inspect" do
    assert {:ok, user} =
             Users.register_oauth_user(%{
               github_id: "redact_linear_gh",
               login: "redact_linear_test",
               email: "redact_linear@example.com"
             })

    assert {:ok, linked_user} =
             user
             |> User.changeset(%{
               linear_access_token: "secret-linear-access-token",
               linear_refresh_token: "secret-linear-refresh-token",
               linear_token_expires_at: DateTime.utc_now()
             })
             |> Repo.update()

    inspected = inspect(linked_user)
    refute String.contains?(inspected, "secret-linear-access-token")
    refute String.contains?(inspected, "secret-linear-refresh-token")
    refute String.contains?(inspected, "linear_access_token:")
    refute String.contains?(inspected, "linear_refresh_token:")
  end

  test "the signing fingerprint is the one GitHub shows for the key" do
    user = %User{signing_public_key: "ssh-ed25519 " <> Base.encode64("the key blob") <> " ada@example.com"}

    assert User.signing_fingerprint(user) ==
             "SHA256:" <> Base.encode64(:crypto.hash(:sha256, "the key blob"), padding: false)
  end

  test "a key that is not an ssh public key line has no fingerprint" do
    assert User.signing_fingerprint(%User{signing_public_key: "nonsense"}) == nil
    assert User.signing_fingerprint(%User{signing_public_key: nil}) == nil
  end

  test "a user with no key does not sign" do
    refute User.signing?(%User{})
    assert User.signing?(%User{signing_key: "-----BEGIN OPENSSH PRIVATE KEY-----"})
  end
end
