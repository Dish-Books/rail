defmodule Rail.Pipeline.Actions.GetImplementationPlan do
  @moduledoc false

  alias Rail.Pipeline.Schemas.ImplementationPlan
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Gets the implementation plan for `task`.
  """
  def get_implementation_plan(%Task{id: task_id}) do
    case Repo.get_by(ImplementationPlan, task_id: task_id) do
      %ImplementationPlan{} = plan -> {:ok, plan}
      nil -> {:error, :not_found}
    end
  end
end
