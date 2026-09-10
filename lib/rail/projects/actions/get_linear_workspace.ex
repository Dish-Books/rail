defmodule Rail.Projects.Actions.GetLinearWorkspace do
  @moduledoc false

  import Ecto.Query

  alias Rail.Projects.Schemas.LinearWorkspace
  alias Rail.Repo

  def get_linear_workspace(id) when is_binary(id) do
    case Repo.get(LinearWorkspace, id) do
      %LinearWorkspace{} = lw -> {:ok, lw}
      nil -> {:error, :not_found}
    end
  end

  def get_linear_workspace(_scope_or_other) do
    case Repo.one(from lw in LinearWorkspace, limit: 1) do
      %LinearWorkspace{} = lw -> {:ok, lw}
      nil -> {:error, :not_found}
    end
  end

  def get_linear_workspace!(id) when is_binary(id) do
    Repo.get!(LinearWorkspace, id)
  end

  def get_linear_workspace!(_scope_or_other) do
    case Repo.one(from lw in LinearWorkspace, limit: 1) do
      %LinearWorkspace{} = lw -> lw
      nil -> raise Ecto.NoResultsError, queryable: LinearWorkspace
    end
  end
end
