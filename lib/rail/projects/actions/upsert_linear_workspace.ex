defmodule Rail.Projects.Actions.UpsertLinearWorkspace do
  @moduledoc false

  import Ecto.Query

  alias Rail.Projects.Schemas.LinearWorkspace
  alias Rail.Repo

  def upsert_linear_workspace(_scope, attrs) do
    case Repo.one(from lw in LinearWorkspace, limit: 1) do
      %LinearWorkspace{} = existing ->
        existing
        |> LinearWorkspace.changeset(attrs)
        |> Repo.update()

      nil ->
        %LinearWorkspace{}
        |> LinearWorkspace.changeset(attrs)
        |> Repo.insert()
    end
  end
end
