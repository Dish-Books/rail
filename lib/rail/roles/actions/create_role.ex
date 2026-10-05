defmodule Rail.Roles.Actions.CreateRole do
  @moduledoc false

  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role

  def create_role(_scope, %Project{} = project, attrs) do
    %Role{project_id: project.id} |> Role.changeset(attrs) |> Repo.insert()
  end
end
