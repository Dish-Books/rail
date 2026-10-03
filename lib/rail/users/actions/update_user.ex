defmodule Rail.Users.Actions.UpdateUser do
  @moduledoc false

  alias Rail.Repo
  alias Rail.Users.Schemas.User

  def update_user(_scope, %User{} = user, attrs) do
    case user |> User.changeset(attrs) |> Repo.update() do
      {:ok, user} ->
        Phoenix.PubSub.broadcast(Rail.PubSub, "users", {:users_changed, user.id})
        {:ok, user}

      {:error, changeset} ->
        {:error, changeset}
    end
  end
end
