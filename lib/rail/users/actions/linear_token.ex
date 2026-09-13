defmodule Rail.Users.Actions.LinearToken do
  @moduledoc false

  alias Rail.Linear.Client, as: LinearClient
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users.Schemas.User

  @expiry_threshold_seconds 300

  def linear_token(%Scope{user: %User{id: id}}), do: do_linear_token(id)
  def linear_token(%Scope{user: %{id: id}}) when is_binary(id), do: do_linear_token(id)
  def linear_token(%User{id: id}), do: do_linear_token(id)
  def linear_token(id) when is_binary(id), do: do_linear_token(id)
  def linear_token(_scope), do: {:error, :not_linked}

  defp do_linear_token(user_id) do
    case Repo.get(User, user_id) do
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
    expires_in = tokens[:expires_in]

    expires_at =
      if is_integer(expires_in) do
        DateTime.shift(DateTime.utc_now(), second: expires_in)
      else
        tokens[:expires_at]
      end

    user
    |> User.changeset(%{
      linear_access_token: tokens.access_token,
      linear_refresh_token: tokens[:refresh_token] || user.linear_refresh_token,
      linear_token_expires_at: expires_at
    })
    |> Repo.update()
    |> case do
      {:ok, _updated_user} -> {:ok, tokens.access_token}
      {:error, changeset} -> {:error, changeset}
    end
  end
end
