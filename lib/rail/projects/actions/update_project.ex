defmodule Rail.Projects.Actions.UpdateProject do
  @moduledoc false

  import Rail.Projects.Utils.MatchLinearWorkspace

  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  def update_project(_scope, %Project{} = project, attrs) do
    project
    |> match_linear_workspace(attrs)
    |> Project.changeset(attrs)
    |> Repo.update()
  end
end
