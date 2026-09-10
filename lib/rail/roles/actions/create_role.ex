defmodule Rail.Roles.Actions.CreateRole do
  @moduledoc false

  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role

  def create_role(_scope, project_or_id, attrs) do
    project_id = extract_project_id(project_or_id)

    %Role{}
    |> Role.changeset(attrs, project_id)
    |> Repo.insert()
  end

  defp extract_project_id(%Project{id: id}), do: id
  defp extract_project_id(id) when is_binary(id), do: id
  defp extract_project_id(_other), do: nil
end
