defmodule Rail.Users.Actions.UnlinkLinear do
  @moduledoc false

  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users.Schemas.User

  def unlink_linear(%Scope{user: %User{id: id}}), do: do_unlink_linear(id)
  def unlink_linear(%Scope{user: %{id: id}}) when is_binary(id), do: do_unlink_linear(id)
  def unlink_linear(%User{id: id}), do: do_unlink_linear(id)
  def unlink_linear(id) when is_binary(id), do: do_unlink_linear(id)
  def unlink_linear(_scope), do: {:error, :not_authorized}

  defp do_unlink_linear(user_id) do
    case Repo.get(User, user_id) do
      %User{} = user ->
        user
        |> User.linear_unlink_changeset()
        |> Repo.update()

      nil ->
        {:error, :not_found}
    end
  end
end
