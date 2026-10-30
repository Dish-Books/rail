defmodule Rail.Users.Actions.SetIssuesFilters do
  @moduledoc false

  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users.Schemas.User

  @doc """
  Replaces the scope's user's Issues filters with `filters`, the URL parameters that set them. Returns the updated user.
  """
  def set_issues_filters(%Scope{user: %User{id: user_id}}, %{} = filters) do
    User
    |> Repo.get!(user_id)
    |> User.issues_filters_changeset(%{issues_filters: filters})
    |> Repo.update()
  end

  def set_issues_filters(_scope, _filters), do: {:error, :not_authenticated}
end
