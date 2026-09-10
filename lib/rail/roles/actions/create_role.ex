defmodule Rail.Roles.Actions.CreateRole do
  @moduledoc false

  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role
  alias Rail.Scope
  alias Rail.Users

  def create_role(scope, project_or_id, attrs) do
    if Scope.admin?(scope) or Users.can?(scope, :manage_roles) do
      project_id = extract_project_id(project_or_id)

      %Role{}
      |> Role.changeset(attrs, project_id)
      |> Repo.insert()
    else
      {:error, :not_authorized}
    end
  end

  defp extract_project_id(%Project{id: id}), do: id
  defp extract_project_id(id) when is_binary(id), do: id
  defp extract_project_id(_other), do: nil
end
