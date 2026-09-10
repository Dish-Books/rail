defmodule Rail.Projects.Actions.CreateProject do
  @moduledoc false

  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  def create_project(_scope, attrs) do
    %Project{}
    |> Project.changeset(attrs)
    |> Repo.insert()
  end
end
