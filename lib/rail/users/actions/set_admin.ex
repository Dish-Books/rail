defmodule Rail.Users.Actions.SetAdmin do
  @moduledoc false

  import Ecto.Query

  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users.Schemas.User

  def set_admin(scope, %User{} = user, admin_bool) when is_boolean(admin_bool) do
    do_set_admin(scope, user, admin_bool)
  end

  def set_admin(scope, user_id, admin_bool) when is_binary(user_id) and is_boolean(admin_bool) do
    user = Repo.get!(User, user_id)
    do_set_admin(scope, user, admin_bool)
  end

  defp do_set_admin(scope, %User{} = user, admin_bool) do
    if not admin_bool and removing_self_admin?(scope, user) and sole_admin?() do
      {:error, :cannot_remove_sole_admin}
    else
      user
      |> User.admin_changeset(%{admin: admin_bool})
      |> Repo.update()
    end
  end

  defp removing_self_admin?(%Scope{user: %{id: scope_user_id}}, %User{id: target_user_id}) do
    scope_user_id == target_user_id
  end

  defp removing_self_admin?(_scope, _user), do: false

  defp sole_admin? do
    admin_count = Repo.one(from u in User, where: u.admin == true, select: count(u.id))
    admin_count <= 1
  end
end
