defmodule Rail.Users.Actions.LinkGitHubTest do
  use Rail.DataCase, async: true

  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users
  alias Rail.Users.Schemas.User
  alias Ueberauth.Auth

  setup do
    id = System.unique_integer([:positive])

    {:ok, tester} =
      Users.register_oauth_user(%{github_id: "gh_tester_#{id}", login: "tester-#{id}", email: "luis-#{id}@x.io"})

    {:ok, %User{id: tester_id, email: tester_email} = tester} = Users.unlink_github(Scope.for_user(tester))

    auth = %Auth{
      uid: 7_000 + id,
      info: %Auth.Info{nickname: "luisgh-#{id}", name: "Luis Ortega", email: "personal-#{id}@gmail.com"},
      credentials: %Auth.Credentials{token: "gho_first", refresh_token: "ghr_first", expires_at: 4_102_444_800}
    }

    %{tester: tester, tester_id: tester_id, tester_email: tester_email, auth: auth, id: id}
  end

  test "connects GitHub to the signed-in user, keeping their Rail email", %{
    tester: tester,
    tester_id: tester_id,
    tester_email: email,
    auth: auth,
    id: id
  } do
    github_id = to_string(7_000 + id)
    login = "luisgh-#{id}"
    Phoenix.PubSub.subscribe(Rail.PubSub, "users")

    assert {:ok, %User{id: ^tester_id, github_id: ^github_id, login: ^login, name: "Luis Ortega", email: ^email}} =
             Users.link_github(Scope.for_user(tester), auth)

    assert %User{github_token: "gho_first", github_refresh_token: "ghr_first"} = Repo.get!(User, tester_id)
    assert_receive {:users_changed, ^tester_id}
  end

  test "linking the same account again refreshes its tokens, as Reconnect does", %{tester: tester, auth: auth} do
    {:ok, linked} = Users.link_github(Scope.for_user(tester), auth)
    auth = %{auth | credentials: %Auth.Credentials{token: "gho_second", refresh_token: "ghr_second"}}

    assert {:ok, %User{github_token: "gho_second", github_refresh_token: "ghr_second", github_token_expires_at: nil}} =
             Users.link_github(Scope.for_user(linked), auth)
  end

  test "refuses a GitHub account another user holds, returning them, and changes neither", %{
    tester: tester,
    auth: auth,
    id: id
  } do
    {:ok, %User{id: holder_id} = holder} =
      Users.register_oauth_user(%{
        github_id: to_string(7_000 + id),
        login: "priyar-#{id}",
        name: "Priya Raman",
        email: "priya-#{id}@x.io"
      })

    assert {:error, {:github_taken, %User{id: ^holder_id, name: "Priya Raman"}}} =
             Users.link_github(Scope.for_user(tester), auth)

    assert %User{github_id: nil, login: nil, github_token: nil} = Repo.reload!(tester)
    assert Repo.reload!(holder) == holder
  end

  test "refuses a second GitHub account on a user who has one", %{tester: tester, auth: auth, id: id} do
    {:ok, linked} = Users.link_github(Scope.for_user(tester), auth)
    other = %{auth | uid: 9_000 + id, info: %{auth.info | nickname: "other-#{id}"}}

    assert {:error, {:github_already_linked, ^linked}} = Users.link_github(Scope.for_user(linked), other)
    assert Repo.reload!(linked) == linked
  end

  test "refuses a GitHub profile with no login, as sign-up does", %{tester: tester, auth: auth} do
    auth = %{auth | info: %{auth.info | nickname: nil, name: nil}}

    assert {:error, %Ecto.Changeset{} = changeset} = Users.link_github(Scope.for_user(tester), auth)
    assert %{login: ["can't be blank"]} = errors_on(changeset)
    assert %User{github_id: nil} = Repo.reload!(tester)
  end
end
