defmodule Rail.Users.Actions.ListAssignableUsers do
  @moduledoc false

  import Ecto.Query

  alias Rail.Repo
  alias Rail.Users.Schemas.User

  @doc """
  Lists the users an issue can be assigned to: in `:tracker` `:linear` (the default) those who
  linked a Linear account, in `:github` everyone, since everyone signs in with GitHub.
  `:project_id` keeps the admins and the users granted that project.
  """
  def list_assignable_users(opts \\ []) do
    User
    |> then(
      &if(opts[:tracker] == :github,
        do: where(&1, [u], not is_nil(u.github_id)),
        else: where(&1, [u], not is_nil(u.linear_user_id))
      )
    )
    |> then(&if(id = opts[:project_id], do: where(&1, [u], u.admin or ^id in u.project_ids), else: &1))
    |> order_by([u], asc: u.name, asc: u.login)
    |> Repo.all()
  end
end
