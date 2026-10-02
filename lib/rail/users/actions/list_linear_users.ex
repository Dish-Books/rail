defmodule Rail.Users.Actions.ListLinearUsers do
  @moduledoc false

  import Ecto.Query

  alias Rail.Repo
  alias Rail.Users.Schemas.User

  @doc """
  Lists the users who have linked a Linear account, the only ones an issue can
  be assigned to. `:project_id` keeps the admins and the users granted that project.
  """
  def list_linear_users(opts \\ []) do
    User
    |> where([u], not is_nil(u.linear_user_id))
    |> then(&if(id = opts[:project_id], do: where(&1, [u], u.admin or ^id in u.project_ids), else: &1))
    |> order_by([u], asc: u.name, asc: u.login)
    |> Repo.all()
  end
end
