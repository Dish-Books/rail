defmodule Rail.Users.Actions.LinkLinear do
  @moduledoc """
  Connects the scope's user to their Linear account from an OAuth callback.
  """

  alias Rail.Linear.Client, as: Linear
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users.Schemas.User

  @doc """
  Trades the authorization `code` for tokens, reads who they belong to, and
  stores both on the scope's user.
  """
  def link_linear(%Scope{user: %User{} = user}, code) when is_binary(code) do
    with {:ok, %{"access_token" => access_token} = tokens} <- Linear.exchange_code(code),
         {:ok, %{"viewer" => viewer}} <- Linear.viewer(access_token) do
      user
      |> User.changeset(%{
        linear_user_id: viewer["id"],
        linear_name: viewer["name"],
        linear_access_token: access_token,
        linear_refresh_token: tokens["refresh_token"],
        linear_token_expires_at: expires_at(tokens["expires_in"])
      })
      |> Repo.update()
    end
  end

  def link_linear(_scope, _code), do: {:error, :not_authenticated}

  defp expires_at(seconds) when is_integer(seconds), do: DateTime.shift(DateTime.utc_now(), second: seconds)
  defp expires_at(_never), do: nil
end
