defmodule Rail.Users.Actions.ListUsersByIds do
  @moduledoc """
  The people behind a set of ids, so anyone signed in can see who said what on a
  task they can read. Listing everyone stays an admin's.
  """

  import Ecto.Query

  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users.Schemas.User

  @doc """
  Returns the users among `ids`, skipping any that no longer exist.
  """
  def list_users_by_ids(%Scope{}, ids) when is_list(ids) do
    Repo.all(from u in User, where: u.id in ^ids, order_by: [asc: u.id])
  end
end
