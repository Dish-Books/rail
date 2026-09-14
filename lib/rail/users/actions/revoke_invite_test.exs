defmodule Rail.Users.Actions.RevokeInviteTest do
  use Rail.DataCase, async: true

  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users
  alias Rail.Users.Schemas.Invite
  alias Rail.Users.Schemas.User

  setup do
    id = System.unique_integer([:positive])

    assert {:ok, %User{} = admin} =
             Users.register_oauth_user(%{
               github_id: "revoker_gh_#{id}",
               login: "revoker_#{id}",
               email: "revoker_#{id}@example.com",
               admin: true
             })

    %{admin: admin, scope: Scope.for_user(admin), id: id}
  end

  test "revoking removes the standing permission", %{scope: scope} do
    assert {:ok, %Invite{id: invite_id}} = Users.invite_user(scope, %{email: "gone@example.com"})

    assert {:ok, %Invite{}} = Users.revoke_invite(scope, invite_id)
    assert Repo.get(Invite, invite_id) == nil
  end

  test "an accepted invite is kept as the record of how the account got in", %{scope: scope} do
    assert {:ok, %Invite{id: invite_id} = invite} = Users.invite_user(scope, %{email: "kept@example.com"})
    assert {:ok, _updated} = invite |> Invite.changeset(%{accepted_at: DateTime.utc_now()}) |> Repo.update()

    assert {:error, :already_accepted} = Users.revoke_invite(scope, invite_id)
    assert %Invite{} = Repo.get(Invite, invite_id)
  end

  test "reports a missing invite", %{scope: scope} do
    assert {:error, :not_found} = Users.revoke_invite(scope, "inv_missing")
  end

  test "non-admins cannot revoke", %{scope: scope, id: id} do
    assert {:ok, %Invite{id: invite_id}} = Users.invite_user(scope, %{email: "safe@example.com"})

    assert {:ok, %User{} = regular} =
             Users.register_oauth_user(%{
               github_id: "norevoke_gh_#{id}",
               login: "norevoke_#{id}",
               email: "norevoke_#{id}@example.com"
             })

    assert {:error, :not_authorized} = Users.revoke_invite(Scope.for_user(regular), invite_id)
    assert %Invite{} = Repo.get(Invite, invite_id)
  end
end
