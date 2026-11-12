defmodule Rail.Users.Utils.AdmitUser do
  @moduledoc false

  import Ecto.Query

  alias Rail.Repo
  alias Rail.Users.Schemas.Invite
  alias Rail.Users.Schemas.User

  @doc """
  Lets a signed-in identity become a user, inside the caller's transaction: a returning user, the first one,
  or an open invite's address, whose projects and admin it grants. `register` creates or refreshes the user, rolling back when it cannot.
  """
  def admit_user(github_id, email, register) when is_function(register, 0) do
    cond do
      existing_user?(github_id, email) -> register.()
      # An empty instance has nobody to issue the first invite, so the first person in becomes the admin.
      Repo.aggregate(User, :count) == 0 -> promote(register.())
      blank?(email) -> Repo.rollback(:no_email)
      invite = open_invite(email) -> redeem(register, invite)
      true -> Repo.rollback(:not_invited)
    end
  end

  defp existing_user?(github_id, email) do
    (not blank?(github_id) and Repo.exists?(from u in User, where: u.github_id == ^github_id)) or
      (not blank?(email) and Repo.exists?(from u in User, where: u.email == ^email))
  end

  defp open_invite(email), do: Repo.one(from i in Invite, where: i.email == ^email and is_nil(i.accepted_at))

  defp redeem(register, %Invite{} = invite) do
    user = if invite.admin, do: promote(register.()), else: register.()
    user = user |> User.changeset(%{project_ids: invite.project_ids}) |> Repo.update!()

    # Two server-side fields on a row just read, so a failure here is a bug, not a refused sign-in.
    invite
    |> Invite.changeset(%{accepted_at: DateTime.utc_now(), accepted_user_id: user.id})
    |> Repo.update!()

    user
  end

  # Only ever a user just created, who is not an admin yet.
  defp promote(%User{} = user), do: user |> User.changeset(%{admin: true}) |> Repo.update!()

  defp blank?(value), do: is_nil(value) or value == ""
end
