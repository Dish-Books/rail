defmodule Rail.Users.Actions.InviteUser do
  @moduledoc false

  alias Rail.Repo
  alias Rail.Users.Schemas.Invite

  # Re-inviting an address reuses its row rather than colliding with it: an invite is
  # a standing permission, not a message, so sending it twice should be harmless. An
  # invite that was already redeemed is not reopened — that account exists now.
  def invite_user(scope, attrs) do
    attrs = attrs |> normalize() |> Map.put(:invited_by_id, scope.user && scope.user.id)

    case Repo.get_by(Invite, email: attrs.email) do
      %Invite{accepted_at: nil} = invite -> save(invite, attrs)
      %Invite{} -> {:error, :already_accepted}
      nil -> save(%Invite{}, attrs)
    end
  end

  defp save(invite, attrs) do
    invite
    |> Invite.changeset(attrs)
    |> Repo.insert_or_update()
  end

  defp normalize(attrs) do
    %{
      email: attrs |> Attrs.get(:email) |> to_string() |> String.trim() |> String.downcase(),
      admin: Attrs.get(attrs, :admin) in [true, "true", "on"]
    }
  end
end
