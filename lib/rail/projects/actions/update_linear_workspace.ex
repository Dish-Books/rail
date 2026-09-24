defmodule Rail.Projects.Actions.UpdateLinearWorkspace do
  @moduledoc false

  alias Rail.Projects.Schemas.LinearWorkspace
  alias Rail.Repo

  def update_linear_workspace(_scope, %LinearWorkspace{} = workspace, attrs) do
    workspace
    |> LinearWorkspace.changeset(attrs)
    |> Repo.update()
  end
end
