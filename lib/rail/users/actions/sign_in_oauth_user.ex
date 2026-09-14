defmodule Rail.Users.Actions.SignInOAuthUser do
  @moduledoc false

  import Ecto.Query

  alias Rail.Repo
  alias Rail.Users
  alias Rail.Users.Schemas.Invite
  alias Rail.Users.Schemas.User

  # Authenticating and being allowed in are different questions. GitHub vouches for
  # any account on the internet, so a first-time sign-in has to redeem an invite for
  # the address GitHub reports. People who already have a user row are untouched by
  # this: they authenticate, their profile refreshes, and no invite is consumed.
  def sign_in_oauth_user(%Ueberauth.Auth{} = auth) do
    email = auth.info && auth.info.email && String.trim(auth.info.email)
    github_id = auth.uid && to_string(auth.uid)

    Repo.transaction(fn ->
      case admit(github_id, email) do
        :returning -> register(auth, false)
        :bootstrap -> register(auth, true)
        {:invite, invite} -> redeem(auth, invite)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp admit(github_id, email) do
    cond do
      existing_user?(github_id, email) -> :returning
      # An empty instance has nobody to issue the first invite, so the first account
      # through the door bootstraps itself as the admin who invites everyone else.
      Repo.aggregate(User, :count) == 0 -> :bootstrap
      blank?(email) -> {:error, :no_email}
      true -> open_invite(email)
    end
  end

  defp existing_user?(github_id, email) do
    (is_binary(github_id) and github_id != "" and Repo.exists?(from u in User, where: u.github_id == ^github_id)) or
      (not blank?(email) and Repo.exists?(from u in User, where: u.email == ^email))
  end

  defp open_invite(email) do
    case Repo.one(from i in Invite, where: i.email == ^email and is_nil(i.accepted_at)) do
      %Invite{} = invite -> {:invite, invite}
      nil -> {:error, :not_invited}
    end
  end

  defp redeem(auth, %Invite{} = invite) do
    user = register(auth, invite.admin)

    # Stamping the invite cannot fail on user input — it is two server-side fields on a
    # row we just read — so a failure here is a bug, not a rejected sign-in.
    invite
    |> Invite.changeset(%{accepted_at: DateTime.utc_now(), accepted_user_id: user.id})
    |> Repo.update!()

    user
  end

  defp register(auth, admin) do
    case Users.register_oauth_user(auth) do
      {:ok, user} -> promote(user, admin)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp promote(%User{admin: true} = user, _admin), do: user
  defp promote(%User{} = user, false), do: user

  defp promote(%User{} = user, true) do
    user
    |> User.changeset(%{admin: true})
    |> Repo.update!()
  end

  defp blank?(value), do: is_nil(value) or value == ""
end
