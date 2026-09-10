defmodule Rail.Projects.Actions.CreateProject do
  @moduledoc false

  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users

  def create_project(scope, attrs) do
    if Scope.admin?(scope) or Users.can?(scope, :create_project) do
      %Project{}
      |> Project.changeset(attrs)
      |> Repo.insert()
    else
      {:error, :not_authorized}
    end
  end
end
