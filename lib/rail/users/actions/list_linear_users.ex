defmodule Rail.Users.Actions.ListLinearUsers do
  @moduledoc false

  import Ecto.Query

  alias Rail.Repo
  alias Rail.Users.Schemas.User

  @doc """
  Lists the users who have linked a Linear account, the only ones an issue can
  be assigned to.
  """
  def list_linear_users do
    Repo.all(from u in User, where: not is_nil(u.linear_user_id), order_by: [asc: u.name, asc: u.login])
  end
end
