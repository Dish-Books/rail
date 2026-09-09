defmodule Rail.Users.Schemas.UserTest do
  use Rail.DataCase, async: true

  alias Rail.Users
  alias Rail.Users.Schemas.User

  test "factory builds a valid user struct" do
    user = User.factory()
    assert byte_size(user.github_id) > 0
    assert byte_size(user.login) > 0
    assert byte_size(user.email) > 0
    assert user.admin == false
  end

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
end
