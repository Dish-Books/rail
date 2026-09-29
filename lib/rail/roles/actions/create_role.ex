defmodule Rail.Roles.Actions.CreateRole do
  @moduledoc false

  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role

  # The backend comes back loaded, so a freshly created role is as usable as one
  # read through `Roles.get_role/1`.
  def create_role(_scope, %Project{} = project, attrs) do
    case %Role{project_id: project.id} |> Role.changeset(attrs) |> Repo.insert() do
      {:ok, role} -> {:ok, Repo.preload(role, :backend)}
      {:error, changeset} -> {:error, changeset}
    end
  end
end
