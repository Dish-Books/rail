defmodule Rail.Users.Actions.RevokeInvite do
  @moduledoc false

  alias Rail.Repo
  alias Rail.Users.Schemas.Invite

  # Revoking only ever takes back an unused invite. Once it has been redeemed the
  # account is the thing that grants access, and deleting the invite would quietly
  # erase the record of how that account came to exist.
  def revoke_invite(_scope, invite_id) do
    case Repo.get(Invite, invite_id) do
      %Invite{accepted_at: nil} = invite -> Repo.delete(invite)
      %Invite{} -> {:error, :already_accepted}
      nil -> {:error, :not_found}
    end
  end
end
