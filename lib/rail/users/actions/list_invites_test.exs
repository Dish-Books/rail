defmodule Rail.Users.Actions.ListInvitesTest do
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
               github_id: "lister_gh_#{id}",
               login: "lister_#{id}",
               email: "lister_#{id}@example.com",
               admin: true
             })

    %{admin_id: admin_id, scope: Scope.for_user(admin), id: id}
  end

  test "lists pending invites before accepted ones, with the inviter preloaded", %{
    admin_id: admin_id,
    scope: scope
  } do
    assert {:ok, %Invite{} = accepted} = Users.invite_user(scope, %{email: "accepted@example.com"})
    assert {:ok, _updated} = accepted |> Invite.changeset(%{accepted_at: DateTime.utc_now()}) |> Repo.update()
    assert {:ok, %Invite{}} = Users.invite_user(scope, %{email: "pending@example.com"})

    assert {:ok,
            [
              %Invite{email: "pending@example.com", accepted_at: nil, invited_by: %User{id: ^admin_id}},
              %Invite{email: "accepted@example.com", accepted_at: %DateTime{}}
            ]} = Users.list_invites(scope)
  end

  test "non-admins cannot list invites", %{id: id} do
    assert {:ok, %User{} = regular} =
             Users.register_oauth_user(%{
               github_id: "reader_gh_#{id}",
               login: "reader_#{id}",
               email: "reader_#{id}@example.com"
             })

    assert {:error, :not_authorized} = Users.list_invites(Scope.for_user(regular))
  end
end
