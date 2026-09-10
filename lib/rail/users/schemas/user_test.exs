defmodule Rail.Users.Schemas.UserTest do
  use Rail.DataCase, async: true

  alias Rail.Users
  alias Rail.Users.Schemas.User

  test "oauth_changeset validates required fields" do
    changeset = User.oauth_changeset(%User{}, %{})

    assert %{
             github_id: ["can't be blank"],
             login: ["can't be blank"],
             email: ["can't be blank"]
           } = errors_on(changeset)
  end

  test "oauth_changeset accepts valid attributes" do
    attrs = %{
      github_id: "12345",
      login: "octocat",
      name: "Mona Lisa",
      email: "octocat@github.com",
      avatar_url: "https://example.com/avatar.png",
      github_token: "gho_secret123",
      admin: true
    }

    changeset = User.oauth_changeset(%User{}, attrs)
    assert changeset.valid?
  end

  test "oauth_changeset enforces uniqueness on github_id, login, and email" do
    assert {:ok, %User{github_id: github_id, login: login, email: email}} =
             Users.register_oauth_user(%{
               github_id: "unique_gh_id",
               login: "unique_login",
               email: "unique@example.com"
             })

    assert {:error, changeset1} =
             %User{}
             |> User.oauth_changeset(%{github_id: github_id, login: "other1", email: "other1@example.com"})
             |> Repo.insert()

    assert %{github_id: ["has already been taken"]} = errors_on(changeset1)

    assert {:error, changeset2} =
             %User{}
             |> User.oauth_changeset(%{github_id: "other2", login: login, email: "other2@example.com"})
             |> Repo.insert()

    assert %{login: ["has already been taken"]} = errors_on(changeset2)

    assert {:error, changeset3} =
             %User{}
             |> User.oauth_changeset(%{github_id: "other3", login: "other3", email: email})
             |> Repo.insert()

    assert %{email: ["has already been taken"]} = errors_on(changeset3)
  end

  test "admin_changeset updates admin flag" do
    assert {:ok, user} =
             Users.register_oauth_user(%{
               github_id: "admin_test_gh",
               login: "admin_test",
               email: "admintest@example.com"
             })

    assert {:ok, %User{admin: true}} =
             user
             |> User.admin_changeset(%{admin: true})
             |> Repo.update()

    assert {:error, changeset} =
             user
             |> User.admin_changeset(%{admin: nil})
             |> Repo.update()

    assert %{admin: ["can't be blank"]} = errors_on(changeset)
  end

  test "project_filter_changeset updates last_project_filter" do
    assert {:ok, user} =
             Users.register_oauth_user(%{
               github_id: "filter_test_gh",
               login: "filter_test",
               email: "filtertest@example.com"
             })

    assert {:ok, %User{last_project_filter: "prj_123"}} =
             user
             |> User.project_filter_changeset(%{last_project_filter: "prj_123"})
             |> Repo.update()
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

  test "linear_link_changeset validates required fields and sets linear attrs" do
    changeset = User.linear_link_changeset(%User{}, %{})

    assert %{
             linear_access_token: ["can't be blank"],
             linear_refresh_token: ["can't be blank"],
             linear_token_expires_at: ["can't be blank"]
           } = errors_on(changeset)

    expires = DateTime.utc_now()

    valid_changeset =
      User.linear_link_changeset(%User{}, %{
        linear_access_token: "lin_at",
        linear_refresh_token: "lin_rt",
        linear_token_expires_at: expires,
        linear_user_id: "lin_usr_1",
        linear_name: "Lin Name"
      })

    assert valid_changeset.valid?
  end

  test "linear_unlink_changeset clears linear attributes" do
    user = %User{
      linear_user_id: "lin_usr_1",
      linear_name: "Lin Name",
      linear_access_token: "lin_at",
      linear_refresh_token: "lin_rt",
      linear_token_expires_at: DateTime.utc_now()
    }

    changeset = User.linear_unlink_changeset(user)

    assert changeset.changes == %{
             linear_user_id: nil,
             linear_name: nil,
             linear_access_token: nil,
             linear_refresh_token: nil,
             linear_token_expires_at: nil
           }
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
             |> User.linear_link_changeset(%{
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
end
