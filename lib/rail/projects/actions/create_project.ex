defmodule Rail.Projects.Actions.CreateProject do
  @moduledoc false

  import Rail.Projects.Utils.MatchLinearWorkspace

  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  def create_project(_scope, attrs) do
    %Project{}
    |> match_linear_workspace(attrs)
    |> Project.changeset(attrs)
    |> Repo.insert()
  end
end
