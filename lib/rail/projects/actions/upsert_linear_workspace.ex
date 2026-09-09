defmodule Rail.Projects.Actions.UpsertLinearWorkspace do
  @moduledoc false

  import Ecto.Query

  alias Rail.Projects.Schemas.LinearWorkspace
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users

  def upsert_linear_workspace(scope, attrs) do
    if authorized?(scope) do
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
    else
      {:error, :not_authorized}
    end
  end

  defp authorized?(%Scope{} = scope) do
    Scope.admin?(scope) or Users.can?(scope, :upsert_linear_workspace)
  end

  defp authorized?(_scope), do: false
end
