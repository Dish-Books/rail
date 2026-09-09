defmodule Rail.Users.Actions.SetProjectFilter do
  @moduledoc false

  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users.Schemas.User

  def set_project_filter(%Scope{user: %User{} = user}, project_id) do
    user
    |> User.project_filter_changeset(%{last_project_filter: project_id})
    |> Repo.update()
  end

  def set_project_filter(%Scope{user: %{id: id}}, project_id) when is_binary(id) do
    User
    |> Repo.get!(id)
    |> User.project_filter_changeset(%{last_project_filter: project_id})
    |> Repo.update()
  end

  def set_project_filter(_scope, _project_id), do: {:error, :not_authorized}
end
