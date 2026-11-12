defmodule Rail.Users.Actions.SignInAccessUser do
  @moduledoc """
  Signs in the person a Cloudflare Access token vouches for, admitted by the same invites as GitHub sign-in.
  """

  import Rail.Users.Utils.AdmitUser

  alias Rail.Repo
  alias Rail.Users.Clients.CloudflareAccess
  alias Rail.Users.Schemas.User

  @doc """
  Verifies `assertion`, the `cf-access-jwt-assertion` header, against the team's current keys and admits its email.
  Refuses a token that is forged, expired, for another application or carries no email, as `:invalid_assertion`.
  """
  def sign_in_access_user(assertion) when is_binary(assertion) do
    with %{team_domain: domain, aud: aud} <- Rail.cloudflare_access() || {:error, :access_off},
         {:ok, keys} <- CloudflareAccess.certs(domain),
         {:ok, email} <- verify(assertion, keys, "https://" <> domain, aud) do
      admit(email)
    end
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

  defp verify(assertion, keys, issuer, aud) do
    now = System.os_time(:second)

    keys
    |> Enum.find_value(fn key ->
      case JOSE.JWT.verify_strict(JOSE.JWK.from_map(key), ["RS256"], assertion) do
        {true, %JOSE.JWT{fields: %{"email" => "" <> email, "iss" => ^issuer, "aud" => auds, "exp" => exp}}, _jws}
        when is_integer(exp) and exp > now and email != "" ->
          aud in List.wrap(auds) && email

        _refused ->
          nil
      end
    end)
    |> then(&if(&1, do: {:ok, &1}, else: {:error, :invalid_assertion}))
  rescue
    # JOSE raises on a string that is not a token at all, which is refused like a forged one.
    _malformed -> {:error, :invalid_assertion}
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
