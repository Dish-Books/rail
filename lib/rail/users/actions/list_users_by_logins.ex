defmodule Rail.Users.Actions.ListUsersByLogins do
  @moduledoc """
  The Rail accounts behind a set of GitHub logins, so people GitHub names are shown by their Rail names.
  """

  import Ecto.Query

  alias Rail.Repo
  alias Rail.Users.Schemas.User

  @doc """
  Returns the users among `logins`, skipping logins no Rail account has.
  """
  def list_users_by_logins(logins) when is_list(logins) do
    Repo.all(from u in User, where: u.login in ^logins, order_by: [asc: u.id])
  end
end
