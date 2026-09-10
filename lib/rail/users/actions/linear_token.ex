defmodule Rail.Users.Actions.LinearToken do
  @moduledoc false

  alias Rail.Linear.Client, as: LinearClient
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users.Schemas.User

  @expiry_threshold_seconds 300

  def linear_token(scope_or_user, opts \\ [])

  def linear_token(%Scope{user: %User{id: id}}, opts), do: do_linear_token(id, opts)
  def linear_token(%Scope{user: %{id: id}}, opts) when is_binary(id), do: do_linear_token(id, opts)
  def linear_token(%User{id: id}, opts), do: do_linear_token(id, opts)
  def linear_token(id, opts) when is_binary(id), do: do_linear_token(id, opts)
  def linear_token(_scope, _opts), do: {:error, :not_linked}

  defp do_linear_token(user_id, opts) do
    case Repo.get(User, user_id) do
      %User{linear_access_token: token} = user when is_binary(token) and token != "" ->
        check_and_maybe_refresh(user, opts)

      _not_linked ->
        {:error, :not_linked}
    end
  end

  defp check_and_maybe_refresh(%User{} = user, opts) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    threshold = DateTime.shift(now, second: @expiry_threshold_seconds)
    expires_at = user.linear_token_expires_at

    needs_refresh = is_nil(expires_at) or DateTime.compare(expires_at, threshold) in [:lt, :eq]

    if needs_refresh do
      refresh_token_and_update(user, now, opts)
    else
      {:ok, user.linear_access_token}
    end
  end

  defp refresh_token_and_update(%User{linear_refresh_token: refresh_token} = user, now, opts)
       when is_binary(refresh_token) and refresh_token != "" do
    client = Keyword.get(opts, :client, LinearClient)

    case client.refresh_token(refresh_token) do
      {:ok, tokens} ->
        persist_refreshed_tokens(user, tokens, now)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp refresh_token_and_update(_user, _now, _opts), do: {:error, :not_linked}

  defp persist_refreshed_tokens(%User{} = user, tokens, now) do
    new_access = tokens.access_token
    new_refresh = tokens[:refresh_token] || user.linear_refresh_token
    expires_in = tokens[:expires_in]

    new_expires_at =
      if is_integer(expires_in) do
        DateTime.shift(now, second: expires_in)
      else
        tokens[:expires_at]
      end

    update_attrs = %{
      linear_access_token: new_access,
      linear_refresh_token: new_refresh,
      linear_token_expires_at: new_expires_at
    }

    user
    |> User.linear_link_changeset(update_attrs)
    |> Repo.update()
    |> case do
      {:ok, _updated_user} -> {:ok, new_access}
      {:error, changeset} -> {:error, changeset}
    end
  end
end
