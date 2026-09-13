defmodule Rail.Users.Actions.UpdateUser do
  @moduledoc false

  alias Rail.Repo
  alias Rail.Users.Schemas.User

  def update_user(_scope, %User{} = user, attrs) do
    user
    |> User.changeset(attrs)
    |> Repo.update()
  end
end
