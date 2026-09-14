defmodule Rail.Pipeline.Actions.GetImplementationPlan do
  @moduledoc """
  The approved plan for a task.

  This is the plan as a later stage reads it, so it is the approved one and never
  whatever is in scratch right now: the architect can still be editing that file
  long after a human said yes to what it used to say.
  """

  alias Rail.Pipeline.Schemas.ImplementationPlan
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Gets the approved implementation plan for `task`.
  """
  def get_implementation_plan(%Task{id: task_id}) do
    case Repo.get_by(ImplementationPlan, task_id: task_id) do
      %ImplementationPlan{} = plan -> {:ok, plan}
      nil -> {:error, :not_found}
    end
  end
end
