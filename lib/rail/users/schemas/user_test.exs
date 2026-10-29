defmodule Rail.Users.Schemas.UserTest do
  use Rail.DataCase, async: true

  alias Rail.Scope
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
      login: "octocat-user",
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
             linear_token_expires_at: nil,
             # No Slack account to message, so notifications are written off with any change.
             slack_notifications: false
           }
  end

  describe "Slack notifications" do
    setup do
      unique = System.unique_integer([:positive])

      {:ok, user} =
        Users.register_oauth_user(%{github_id: "sn_#{unique}", login: "sn_#{unique}", email: "sn_#{unique}@example.com"})

      %{user: user}
    end

    test "turn on for someone with a Slack account to message", %{user: user} do
      {:ok, linked} = Users.update_user(system_scope(), user, %{slack_user_id: "U1", slack_team_id: "T1"})

      assert {:ok, %User{slack_notifications: true}} =
               linked |> User.slack_notifications_changeset(%{slack_notifications: true}) |> Repo.update()
    end

    test "refuse to turn on without a Slack account", %{user: user} do
      changeset = User.slack_notifications_changeset(user, %{slack_notifications: true})

      assert %{slack_notifications: ["connect Slack first"]} = errors_on(changeset)
    end

    test "can be turned off without a Slack account", %{user: user} do
      assert User.slack_notifications_changeset(user, %{slack_notifications: false}).valid?
    end

    test "need a value", %{user: user} do
      assert %{slack_notifications: ["can't be blank"]} =
               errors_on(User.slack_notifications_changeset(user, %{slack_notifications: nil}))
    end

    test "an admin's edit of the user leaves them as they were", %{user: user} do
      {:ok, linked} = Users.update_user(system_scope(), user, %{slack_user_id: "U1", slack_team_id: "T1"})
      {:ok, _on} = linked |> User.slack_notifications_changeset(%{slack_notifications: true}) |> Repo.update()

      assert {:ok, %User{slack_notifications: true}} =
               Users.update_user(system_scope(), Repo.reload!(linked), %{name: "Renamed", slack_notifications: false})

      assert {:ok, %User{slack_notifications: false}} =
               Users.update_user(system_scope(), user, %{name: "Renamed", slack_notifications: true})
    end

    test "unlinking Slack through a stale user still turns them off", %{user: user} do
      {:ok, linked} =
        Users.update_user(system_scope(), user, %{slack_user_id: "U1", slack_team_id: "T1", slack_access_token: "xoxp-1"})

      {:ok, _on} = linked |> User.slack_notifications_changeset(%{slack_notifications: true}) |> Repo.update()

      # The page's scope was loaded before notifications were turned on, so its user still reads off.
      assert {:ok, %User{}} = Users.unlink_slack(Scope.for_user(linked))
      assert %User{slack_notifications: false, slack_user_id: nil} = Repo.reload!(user)
    end
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
