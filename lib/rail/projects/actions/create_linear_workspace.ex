defmodule Rail.Projects.Actions.CreateLinearWorkspace do
  @moduledoc false

  alias Rail.Projects.Schemas.LinearWorkspace
  alias Rail.Repo

  def create_linear_workspace(_scope, attrs) do
    %LinearWorkspace{}
    |> LinearWorkspace.changeset(attrs)
    |> Repo.insert()
  end
end
