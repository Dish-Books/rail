defmodule Rail.Users.Actions.SignInOAuthUserTest do
  use Rail.DataCase, async: true

  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users
  alias Rail.Users.Schemas.Invite
  alias Rail.Users.Schemas.User
  alias Ueberauth.Auth
  alias Ueberauth.Auth.Credentials
  alias Ueberauth.Auth.Info

  setup do
    id = System.unique_integer([:positive])

    email = "newcomer_#{id}@example.com"

    auth = %Auth{
      provider: :github,
      uid: "gh_#{id}",
      info: %Info{
        nickname: "newcomer_#{id}",
        name: "Newcomer #{id}",
        email: email,
        image: "https://example.com/newcomer.png"
      },
      credentials: %Credentials{token: "gho_#{id}"}
    }

    %{auth: auth, email: email, id: id}
  end

  describe "on an empty instance" do
    test "the first account bootstraps itself as admin", %{auth: auth, email: email} do
      assert Repo.aggregate(User, :count) == 0

      assert {:ok, %User{admin: true, email: ^email}} = Users.sign_in_oauth_user(auth)
    end
  end

  describe "once the instance has an account" do
    setup %{id: id} do
      assert {:ok, %User{} = admin} =
               Users.register_oauth_user(%{
                 github_id: "seed_gh_#{id}",
                 login: "seed_#{id}",
                 email: "seed_#{id}@example.com",
                 admin: true
               })

      %{admin: admin, scope: Scope.for_user(admin)}
    end

    test "an uninvited account is turned away and nothing is written", %{auth: auth} do
      assert {:error, :not_invited} = Users.sign_in_oauth_user(auth)
      assert Repo.aggregate(User, :count) == 1
    end

    test "an invited email is admitted and the invite is marked accepted", %{auth: auth, scope: scope} do
      assert {:ok, %Invite{id: invite_id}} = Users.invite_user(scope, %{email: auth.info.email})

      assert {:ok, %User{admin: false, id: user_id}} = Users.sign_in_oauth_user(auth)

      assert %Invite{accepted_at: %DateTime{}, accepted_user_id: ^user_id} = Repo.get(Invite, invite_id)
    end

    test "the invite decides whether the new account is an admin", %{auth: auth, scope: scope} do
      assert {:ok, %Invite{}} = Users.invite_user(scope, %{email: auth.info.email, admin: true})
      assert {:ok, %User{admin: true}} = Users.sign_in_oauth_user(auth)
    end

    test "the invite email matches regardless of case", %{auth: auth, scope: scope} do
      assert {:ok, %Invite{}} = Users.invite_user(scope, %{email: auth.info.email})

      assert {:ok, %User{}} = Users.sign_in_oauth_user(put_in(auth.info.email, String.upcase(auth.info.email)))
    end

    test "an invite is good for one sign-up only", %{auth: auth, scope: scope, id: id} do
      assert {:ok, %Invite{}} = Users.invite_user(scope, %{email: auth.info.email})
      assert {:ok, %User{}} = Users.sign_in_oauth_user(auth)

      # A second GitHub account claiming the same address finds the invite spent — it
      # only gets in because that address is now an account, which is the same door
      # everyone else who already signed up walks through.
      other = %{auth | uid: "other_gh_#{id}", info: %{auth.info | nickname: "other_#{id}"}}

      assert {:ok, %User{}} = Users.sign_in_oauth_user(other)
      assert Repo.aggregate(Invite, :count) == 1
    end

    test "an existing account signs in without an invite and keeps its admin flag", %{auth: auth} do
      assert {:ok, %User{id: existing_id}} =
               Users.register_oauth_user(%{
                 github_id: auth.uid,
                 login: auth.info.nickname,
                 email: auth.info.email
               })

      assert {:ok, %User{id: ^existing_id, admin: false}} = Users.sign_in_oauth_user(auth)
      assert Repo.aggregate(Invite, :count) == 0
    end

    test "an account GitHub reports with no email cannot be matched", %{auth: auth} do
      assert {:error, :no_email} = Users.sign_in_oauth_user(put_in(auth.info.email, nil))
      assert {:error, :no_email} = Users.sign_in_oauth_user(put_in(auth.info.email, "  "))
    end

    test "a broken profile rolls the whole sign-in back", %{auth: auth, scope: scope} do
      assert {:ok, %Invite{id: invite_id}} = Users.invite_user(scope, %{email: auth.info.email})

      assert {:error, %Ecto.Changeset{}} = Users.sign_in_oauth_user(%{auth | uid: nil})
      assert %Invite{accepted_at: nil} = Repo.get(Invite, invite_id)
    end
  end
end
