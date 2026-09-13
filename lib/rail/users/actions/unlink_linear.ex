defmodule Rail.Users.Actions.UnlinkLinear do
  @moduledoc false

  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users.Schemas.User

  @doc """
  Forgets the scope's user's Linear account and tokens.
  """
  def unlink_linear(%Scope{user: %User{} = user}) do
    user
    |> User.changeset(%{
      linear_user_id: nil,
      linear_name: nil,
      linear_access_token: nil,
      linear_refresh_token: nil,
      linear_token_expires_at: nil
    })
    |> Repo.update()
  end

  def unlink_linear(_scope), do: {:error, :not_authenticated}
end
