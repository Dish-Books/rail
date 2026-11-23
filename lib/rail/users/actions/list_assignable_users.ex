defmodule Rail.Users.Actions.ListAssignableUsers do
  @moduledoc false

  import Ecto.Query

  alias Rail.Repo
  alias Rail.Users.Schemas.User

  @doc """
  Lists the users an issue can be assigned to, all of whom have connected GitHub. `:project_id` keeps the admins and the
  users granted that project.
  """
  def list_assignable_users(opts \\ []) do
    User
    |> where([u], not is_nil(u.github_id))
    |> then(&if(id = opts[:project_id], do: where(&1, [u], u.admin or ^id in u.project_ids), else: &1))
    |> order_by([u], asc: u.name, asc: u.login)
    |> Repo.all()
  end
end
