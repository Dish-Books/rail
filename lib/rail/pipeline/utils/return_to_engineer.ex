defmodule Rail.Pipeline.Utils.ReturnToEngineer do
  @moduledoc """
  Code that changes after Engineer has to go back through review and QA.
  """

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Moves `task` back to the engineer stage when it has gone past it, starting
  nothing. Returns `{:ok, task}`, moved or not.
  """
  def return_to_engineer(%Task{} = task) do
    # Callers such as the diff pane can hold a task whose stage has since moved.
    case Repo.get!(Task, task.id) do
      %Task{stage: stage} when stage in [:review, :qa, :demo] -> Pipeline.enter_stage(task, :engineer, start: false)
      %Task{} -> {:ok, task}
    end
  end
end
