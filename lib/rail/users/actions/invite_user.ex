defmodule Rail.Users.Actions.InviteUser do
  @moduledoc false

  import Ecto.Query

  alias Rail.Repo
  alias Rail.Users.Schemas.Invite
  alias Rail.Users.Schemas.User

  # Re-inviting an address reuses its row rather than colliding with it: an invite is
  # a standing permission, not a message, so sending it twice should be harmless. An
  # invite that was already redeemed is not reopened while that account is in use, but
  # is once an admin removed it, which is how a removed person comes back.
  def invite_user(scope, attrs) do
    attrs = attrs |> normalize() |> Map.put(:invited_by_id, scope.user && scope.user.id)

    case Repo.get_by(Invite, email: attrs.email) do
      %Invite{accepted_at: nil} = invite -> save(invite, attrs)
      %Invite{} = invite -> if removed?(attrs.email), do: reopen(invite, attrs), else: {:error, :already_accepted}
      nil -> save(%Invite{}, attrs)
    end
  end

  defp removed?(email), do: Repo.exists?(from u in User, where: u.email == ^email and not is_nil(u.removed_at))

  defp reopen(invite, attrs), do: save(invite, Map.merge(attrs, %{accepted_at: nil, accepted_user_id: nil}))

  defp save(invite, attrs) do
    case invite |> Invite.changeset(attrs) |> Repo.insert_or_update() do
      {:ok, invite} ->
        Phoenix.PubSub.broadcast(Rail.PubSub, "users", {:users_changed, invite.id})
        {:ok, invite}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp normalize(attrs) do
    %{
      email: attrs |> Attrs.get(:email) |> to_string() |> String.trim() |> String.downcase(),
      admin: Attrs.get(attrs, :admin) in [true, "true", "on"],
      role: Attrs.get(attrs, :role) || :dev,
      # A form of checkboxes sends a blank alongside the ticked ones.
      project_ids: attrs |> Attrs.get(:project_ids) |> List.wrap() |> Enum.reject(&(&1 in [nil, ""])) |> Enum.uniq()
    }
  end
end
