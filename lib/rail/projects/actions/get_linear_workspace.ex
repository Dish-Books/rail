defmodule Rail.Projects.Actions.GetLinearWorkspace do
  @moduledoc false

  alias Rail.Projects.Schemas.LinearWorkspace
  alias Rail.Repo

  @doc """
  Finds the Linear workspace matching `by`, e.g. `id: id` or `external_id: id`.
  """
  def get_linear_workspace(by) when is_list(by) do
    case Repo.get_by(LinearWorkspace, by) do
      %LinearWorkspace{} = workspace -> {:ok, workspace}
      nil -> {:error, :not_found}
    end
  end
end
