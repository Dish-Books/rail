defmodule Rail.Users.Actions.ListUsers do
  @moduledoc false

  import Ecto.Query

  alias Rail.Repo
  alias Rail.Users.Schemas.User

  def list_users(_scope) do
    users = Repo.all(from u in User, where: is_nil(u.removed_at), order_by: [asc: u.name, asc: u.inserted_at])
    {:ok, users}
  end
end
