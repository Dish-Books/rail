defmodule Rail.Users.Actions.InviteUserTest do
  use Rail.DataCase, async: true

  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users
  alias Rail.Users.Schemas.Invite
  alias Rail.Users.Schemas.User

  setup do
    id = System.unique_integer([:positive])

    assert {:ok, %User{id: admin_id} = admin} =
             Users.register_oauth_user(%{
               github_id: "inviter_gh_#{id}",
               login: "inviter_#{id}",
               name: "Inviter #{id}",
               email: "inviter_#{id}@example.com",
               admin: true
             })

    %{admin_id: admin_id, scope: Scope.for_user(admin), id: id}
  end

  test "records who issued the invite", %{admin_id: admin_id, scope: scope} do
    assert {:ok, %Invite{email: "new@example.com", admin: false, accepted_at: nil, invited_by_id: ^admin_id}} =
             Users.invite_user(scope, %{email: "new@example.com"})
  end

  test "normalizes the email so sign-up matches regardless of how it was typed", %{scope: scope} do
    assert {:ok, %Invite{email: "mixed@example.com"}} = Users.invite_user(scope, %{email: "  MiXeD@Example.COM  "})
  end

  test "accepts string keys and a checkbox-shaped admin flag", %{scope: scope} do
    assert {:ok, %Invite{email: "checkbox@example.com", admin: true}} =
             Users.invite_user(scope, %{"email" => "checkbox@example.com", "admin" => "on"})
  end

  test "re-inviting an address reuses the row instead of colliding", %{scope: scope} do
    assert {:ok, %Invite{id: invite_id, admin: false}} = Users.invite_user(scope, %{email: "again@example.com"})

    assert {:ok, %Invite{id: ^invite_id, admin: true}} =
             Users.invite_user(scope, %{email: "again@example.com", admin: true})

    assert Repo.aggregate(Invite, :count) == 1
  end

  test "will not reopen an invite that was already redeemed", %{scope: scope} do
    assert {:ok, %Invite{} = invite} = Users.invite_user(scope, %{email: "done@example.com"})

    assert {:ok, _accepted} =
             invite |> Invite.changeset(%{accepted_at: DateTime.utc_now()}) |> Repo.update()

    assert {:error, :already_accepted} = Users.invite_user(scope, %{email: "done@example.com"})
  end

  test "rejects an address that is not an email", %{scope: scope} do
    assert {:error, changeset} = Users.invite_user(scope, %{email: "nope"})
    assert "must be a valid email address" in errors_on(changeset).email

    assert {:error, changeset} = Users.invite_user(scope, %{email: ""})
    assert errors_on(changeset).email != []
  end

  test "only admins may invite", %{id: id} do
    assert {:ok, %User{} = regular} =
             Users.register_oauth_user(%{
               github_id: "regular_gh_#{id}",
               login: "regular_#{id}",
               email: "regular_#{id}@example.com"
             })

    assert {:error, :not_authorized} = Users.invite_user(Scope.for_user(regular), %{email: "nope@example.com"})
  end

  test "a system scope can invite without a user attached" do
    assert {:ok, %Invite{invited_by_id: nil}} = Users.invite_user(Scope.for_system(), %{email: "system@example.com"})
  end
end
