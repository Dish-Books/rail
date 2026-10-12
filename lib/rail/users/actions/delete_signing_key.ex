defmodule Rail.Users.Actions.DeleteSigningKey do
  @moduledoc """
  Takes the scope's user's signing key off GitHub and out of Rail.

  Their commits go unsigned afterwards rather than failing: a missing key is a
  setup step nobody took, not a reason to stop the pipeline.
  """

  alias Rail.GitHub.Client, as: GitHub
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users
  alias Rail.Users.Schemas.User

  @doc """
  Forgets the scope's user's signing key. Returns `:ok`, including when there
  was none, and `{:error, :no_github_token}` when the key is on GitHub and Rail
  cannot reach their account to take it off.
  """
  def delete_signing_key(%Scope{user: %User{signing_key_github_id: key_id} = user} = scope) when is_integer(key_id) do
    with {:ok, token} <- Users.github_token(scope),
         :ok <- GitHub.delete_signing_key(token, key_id) do
      forget(user)
    else
      # A token Rail believed good and GitHub does not: they sign in again, like someone with none.
      {:error, {:github_api_error, 401, _body}} -> {:error, :no_github_token}
      error -> error
    end
  end

  def delete_signing_key(%Scope{user: %User{} = user}), do: forget(user)
  def delete_signing_key(_scope), do: {:error, :not_authenticated}

  defp forget(%User{} = user) do
    {:ok, _user} =
      user
      |> User.changeset(%{signing_key: nil, signing_public_key: nil, signing_key_github_id: nil})
      |> Repo.update()

    :ok
  end
end
