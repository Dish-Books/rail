defmodule Rail.Users.Actions.UnlinkIntercom do
  @moduledoc false

  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users.Schemas.User

  @doc """
  Forgets the scope's user's Intercom account and token.
  """
  def unlink_intercom(%Scope{user: %User{} = user}) do
    with {:ok, user} <-
           user
           |> User.changeset(%{
             intercom_admin_id: nil,
             intercom_app_id: nil,
             intercom_name: nil,
             intercom_access_token: nil
           })
           |> Repo.update() do
      Phoenix.PubSub.broadcast(Rail.PubSub, "users", {:users_changed, user.id})
      {:ok, user}
    end
  end

  def unlink_intercom(_scope), do: {:error, :not_authenticated}
end
