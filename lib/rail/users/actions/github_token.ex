defmodule Rail.Users.Actions.GitHubToken do
  @moduledoc """
  The one place a person's GitHub token is handed out. Rail signs people in through a GitHub App, whose
  tokens last 8 hours, so one that has expired or is about to is renewed first.
  """

  alias Rail.GitHub.Client, as: GitHub
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users.Schemas.User

  @expiry_threshold_seconds 300

  @doc """
  The scope's user's GitHub access token, renewed first when it is about to expire. `{:error, :no_github_token}`
  is someone who has to sign in with GitHub again: Rail holds no token for them, or nothing to renew it with,
  or GitHub refused what it had.
  """
  def github_token(%Scope{user: %{id: user_id}}) do
    case current(user_id) do
      # GitHub spends a refresh token on use, so a second renewal waits for the first and finds its token.
      {:stale, _user} -> :global.trans({{:github_token, user_id}, self()}, fn -> renew(user_id) end)
      result -> result
    end
  end

  def github_token(%Scope{}), do: {:error, :no_github_token}

  defp current(user_id) do
    case Repo.get(User, user_id) do
      %User{github_token: "" <> token} = user when token != "" ->
        if fresh?(user), do: {:ok, token}, else: {:stale, user}

      _no_token ->
        {:error, :no_github_token}
    end
  end

  # No expiry is a token from before Rail kept one, which has long since expired.
  defp fresh?(%User{github_token_expires_at: nil}), do: false

  defp fresh?(%User{github_token_expires_at: expires_at}) do
    threshold = DateTime.shift(DateTime.utc_now(), second: @expiry_threshold_seconds)
    DateTime.after?(expires_at, threshold)
  end

  # Read again under the lock, since the renewal this one waited for has already saved a fresh token.
  defp renew(user_id) do
    with {:stale, user} <- current(user_id), do: refresh_token_and_update(user)
  end

  defp refresh_token_and_update(%User{github_refresh_token: refresh_token} = user)
       when is_binary(refresh_token) and refresh_token != "" do
    case GitHub.refresh_user_token(refresh_token) do
      {:ok, tokens} -> persist_refreshed_tokens(user, tokens)
      # GitHub's refusal, as of a refresh token expired or revoked; one that never reached GitHub can be tried again.
      {:error, {:github_token_refresh_error, status, _body}} when status < 500 -> {:error, :no_github_token}
      {:error, reason} -> {:error, reason}
    end
  end

  defp refresh_token_and_update(_user), do: {:error, :no_github_token}

  defp persist_refreshed_tokens(%User{} = user, tokens) do
    expires_at =
      case tokens["expires_in"] do
        seconds when is_integer(seconds) -> DateTime.shift(DateTime.utc_now(), second: seconds)
        _never -> nil
      end

    # One write, since the refresh token just spent is worthless and the new one is the only way to the next.
    changeset =
      User.changeset(user, %{
        github_token: tokens["access_token"],
        github_refresh_token: tokens["refresh_token"] || user.github_refresh_token,
        github_token_expires_at: expires_at
      })

    with {:ok, _updated_user} <- Repo.update(changeset) do
      {:ok, tokens["access_token"]}
    end
  end
end
