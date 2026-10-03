defmodule Rail.Learnings.Actions.GetLearning do
  @moduledoc false

  alias Rail.Learnings.Schemas.Learning
  alias Rail.Repo

  @doc """
  Loads one learning with its project and approver.
  """
  def get_learning(id) when is_binary(id) do
    case Repo.get(Learning, id) do
      %Learning{} = learning -> {:ok, Repo.preload(learning, [:project, :approved_by])}
      nil -> {:error, :not_found}
    end
  end
end
