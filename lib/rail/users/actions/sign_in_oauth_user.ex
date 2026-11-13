defmodule Rail.Users.Actions.SignInOAuthUser do
  @moduledoc false

  import Rail.Users.Utils.AdmitUser

  alias Rail.Repo
  alias Rail.Users

  # GitHub vouches for any account on the internet, so a first-time sign-in has to redeem an invite for
  # the address GitHub reports. A returning user's profile refreshes and no invite is consumed.
  def sign_in_oauth_user(%Ueberauth.Auth{} = auth) do
    email = auth.info && auth.info.email && String.trim(auth.info.email)
    github_id = auth.uid && to_string(auth.uid)

    fn ->
      admit_user(github_id, email, fn ->
        case Users.register_oauth_user(auth) do
          {:ok, user} -> user
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
    |> Repo.transaction()
    |> case do
      {:ok, user} ->
        Phoenix.PubSub.broadcast(Rail.PubSub, "users", {:users_changed, user.id})
        {:ok, user}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
