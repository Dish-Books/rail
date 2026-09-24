defmodule Rail.Projects.Actions.GetLinearWorkspace do
  @moduledoc false

  import Ecto.Query

  alias Rail.Projects.Schemas.LinearWorkspace
  alias Rail.Repo

  @doc """
  Finds the Linear workspace matching `by`, e.g. `id: id` or `external_id: id`,
  with the projects on it.
  """
  def get_linear_workspace(by) when is_list(by) do
    case Repo.one(from w in LinearWorkspace, where: ^by, preload: :projects) do
      %LinearWorkspace{} = workspace -> {:ok, workspace}
      nil -> {:error, :not_found}
    end
  end
end
