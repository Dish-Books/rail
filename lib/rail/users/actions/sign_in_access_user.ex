defmodule Rail.Users.Actions.SignInAccessUser do
  @moduledoc """
  Signs in the person a Cloudflare Access token vouches for, admitted by the same invites as GitHub sign-in.
  """

  import Rail.Users.Utils.AdmitUser
  import Rail.Users.Utils.VerifyAccessJwt

  alias Rail.Repo
  alias Rail.Users.Clients.CloudflareAccess
  alias Rail.Users.Schemas.User

  @doc """
  Verifies `assertion`, the `cf-access-jwt-assertion` header, against the team's current keys and admits its email.
  Refuses a forged, expired, other application's or emailless token as `:invalid_assertion`, and keys it
  cannot read as `{:access_unreachable, reason}`.
  """
  def sign_in_access_user(assertion) when is_binary(assertion) do
    with %{team_domain: domain, aud: aud} <- Rail.cloudflare_access() || {:error, :access_off},
         {:ok, keys} <- fetch_keys(domain),
         {:ok, email} <- verify(assertion, keys, "https://" <> domain, aud) do
      admit(email)
    end
  end

  defp fetch_keys(domain) do
    with {:error, reason} <- CloudflareAccess.certs(domain), do: {:error, {:access_unreachable, reason}}
  end

  defp admit(email) do
    case Repo.transaction(fn -> admit_user(nil, email, fn -> find_or_insert(email) end) end) do
      {:ok, user} ->
        Phoenix.PubSub.broadcast(Rail.PubSub, "users", {:users_changed, user.id})
        {:ok, user}

      # Named, so the denied page can say which address Access signed in.
      {:error, :not_invited} ->
        {:error, {:not_invited, email}}

      # coveralls-ignore-start (only a second tab inserting the same person reaches it, which the sandbox serializes)
      {:error, reason} ->
        {:error, reason}
        # coveralls-ignore-stop
    end
  end

  # A service token's identity is empty, and signs nobody in.
  defp verify(assertion, keys, issuer, aud) do
    case verify_access_jwt(assertion, keys, issuer, aud) do
      {:ok, %{"email" => "" <> email}} when email != "" -> {:ok, email}
      _refused -> {:error, :invalid_assertion}
    end
  end

  # A returning person is left as they are; a new one has only the email to be named by.
  defp find_or_insert(email) do
    if user = Repo.get_by(User, email: email) do
      user
    else
      %User{}
      |> User.changeset(%{email: email, name: email |> String.split("@") |> hd()})
      |> Repo.insert()
      |> case do
        {:ok, user} ->
          user

        # coveralls-ignore-start (another tab inserted the same person first; the sandbox's one connection cannot race)
        {:error, changeset} ->
          Repo.rollback(changeset)
          # coveralls-ignore-stop
      end
    end
  end
end
