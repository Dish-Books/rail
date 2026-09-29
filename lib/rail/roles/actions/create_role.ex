defmodule Rail.Roles.Actions.CreateRole do
  @moduledoc false

  import Rail.Roles.Utils.SandboxCapacity

  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role

  # The backend comes back loaded, so a freshly created role is as usable as one
  # read through `Roles.get_role/1`.
  def create_role(_scope, %Project{} = project, attrs) do
    changeset = Role.changeset(%Role{project_id: project.id}, attrs, capacity: sandbox_capacity())

    case Repo.insert(changeset) do
      {:ok, role} -> {:ok, Repo.preload(role, :backend)}
      {:error, changeset} -> {:error, changeset}
    end
  end
end
