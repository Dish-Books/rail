defmodule Rail.Users.Actions.LinearToken do
  @moduledoc false

  alias Rail.Linear.Client, as: LinearClient
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users.Schemas.User

  @expiry_threshold_seconds 300

  @doc """
  The scope's user's Linear access token, refreshed first when it is about to
  expire.
  """
  def linear_token(%Scope{user: user}) do
    case Repo.get(User, user.id) do
      %User{linear_access_token: token} = user when is_binary(token) and token != "" ->
        check_and_maybe_refresh(user)

      _not_linked ->
        {:error, :not_linked}
    end
  end

  defp check_and_maybe_refresh(%User{} = user) do
    threshold = DateTime.shift(DateTime.utc_now(), second: @expiry_threshold_seconds)
    expires_at = user.linear_token_expires_at

    if is_nil(expires_at) or DateTime.compare(expires_at, threshold) in [:lt, :eq] do
      refresh_token_and_update(user)
    else
      {:ok, user.linear_access_token}
    end
  end

  defp refresh_token_and_update(%User{linear_refresh_token: refresh_token} = user)
       when is_binary(refresh_token) and refresh_token != "" do
    case LinearClient.refresh_token(refresh_token) do
      {:ok, tokens} -> persist_refreshed_tokens(user, tokens)
      {:error, reason} -> {:error, reason}
    end
  end

  defp refresh_token_and_update(_user), do: {:error, :not_linked}

  defp persist_refreshed_tokens(%User{} = user, tokens) do
    expires_at =
      case tokens["expires_in"] do
        seconds when is_integer(seconds) -> DateTime.shift(DateTime.utc_now(), second: seconds)
        _never -> nil
      end

    changeset =
      User.changeset(user, %{
        linear_access_token: tokens["access_token"],
        linear_refresh_token: tokens["refresh_token"] || user.linear_refresh_token,
        linear_token_expires_at: expires_at
      })

    with {:ok, _updated_user} <- Repo.update(changeset) do
      {:ok, tokens["access_token"]}
    end
  end
end
